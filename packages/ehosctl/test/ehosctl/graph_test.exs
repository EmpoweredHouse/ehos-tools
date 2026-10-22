defmodule Ehosctl.GraphTest do
  # `ehosctl graph <application> <deployment>` (eh-os D-134, ehos-tools#403): a deployment's graph
  # documents, from `GET /api/v1/applications/A/deployments/D/graph` and `…/graph/:kind/:ref`
  # (eh-os#890).
  use Ehosctl.SignInCase

  @id "0b9e6f4c-2d7a-4c1e-9f3b-5a8d1e2c7f60"
  @path "/api/v1/applications/office/deployments/#{@id}/graph"

  @index %{
    "application" => "office",
    "environment" => "staging",
    "deployment" => @id,
    "state" => "active",
    "later_active" => nil,
    "documents" => [
      %{"kind" => "domain", "name" => nil, "domain" => "office", "module" => "Office.Domain"},
      %{
        "kind" => "contract",
        "name" => "office.invoicing",
        "domain" => "office",
        "module" => "Office.Domain"
      },
      %{
        "kind" => "process",
        "name" => "office.month_end",
        "domain" => "office",
        "module" => "Office.Domain"
      }
    ]
  }

  @document %{
    "schema" => "eh_os_contract.graph.v1",
    "kind" => "contract",
    "contract" => "office.invoicing",
    "nodes" => %{"command" => [%{"id" => "command:issue_invoice"}]},
    "relations" => %{}
  }

  @not_found {404,
              %{
                "error" => "not_found",
                "message" =>
                  "That application has no such deployment you may see, or it carried no such " <>
                    "graph document."
              }}

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)
    :ok
  end

  defp serve(provider, path \\ @path, answer),
    do: FakeProvider.stub_api(provider, "GET", path, fn _ -> answer end)

  test "lists the documents the deployment carried", %{provider: provider, opts: opts} do
    serve(provider, {200, @index})

    {0, stdout, ""} = ehosctl(["graph", "office", @id], opts)

    assert stdout =~ "office's deployment #{@id} in staging, active.\n\n"
    assert stdout =~ ~r/KIND +NAME +DOMAIN +MODULE/
    assert stdout =~ ~r/domain +- +office +Office\.Domain/
    assert stdout =~ ~r/contract +office\.invoicing +office +Office\.Domain/
    assert stdout =~ ~r/process +office\.month_end +office +Office\.Domain/

    assert stdout =~
             "Print one with --domain and its MODULE, or --contract or --process and its NAME as the ID."

    refute stdout =~ "later deployment"
  end

  test "says a later deployment is active there, and when nothing was carried",
       %{provider: provider, opts: opts} do
    serve(
      provider,
      {200, %{@index | "state" => "superseded", "later_active" => "later-id", "documents" => []}}
    )

    {0, stdout, ""} = ehosctl(["graph", "office", @id], opts)

    assert stdout =~ "in staging, superseded."
    assert stdout =~ "A later deployment is active there: later-id."
    assert stdout =~ "It carried no graph documents."
  end

  test "--json prints EHOS's answer", %{provider: provider, opts: opts} do
    serve(provider, {200, Map.put(@index, "later", "a key EHOS adds later")})

    {0, stdout, ""} = ehosctl(["graph", "office", @id, "--json"], opts)
    assert JSON.decode!(stdout) == @index
  end

  test "prints one document as JSON, asked for by its kind and its name",
       %{provider: provider, opts: opts} do
    for {option, ref, kind} <- [
          {"--domain", "Office.Domain", "domain"},
          {"--contract", "office.invoicing", "contract"},
          {"--process", "office.month_end", "process"}
        ] do
      document = @document |> Map.delete("contract") |> Map.merge(%{"kind" => kind, kind => ref})
      serve(provider, "#{@path}/#{kind}/#{ref}", {200, document})

      {0, stdout, ""} = ehosctl(["graph", "office", @id, option, ref], opts)
      assert JSON.decode!(stdout) == document
      assert stdout =~ "\n  "

      {0, stdout, ""} = ehosctl(["graph", "office", @id, option, ref, "--json"], opts)
      assert JSON.decode!(stdout) == document
    end
  end

  test "refuses a document other than the one asked for, or none",
       %{provider: provider, opts: opts} do
    for document <- [
          %{@document | "kind" => "process"},
          %{@document | "contract" => "office.payroll"},
          %{"not" => "a graph document"}
        ] do
      serve(provider, "#{@path}/contract/office.invoicing", {200, document})

      {1, "", stderr} = ehosctl(["graph", "office", @id, "--contract", "office.invoicing"], opts)
      assert stderr =~ "cannot read"
    end
  end

  test "refuses an empty name, or . or .., before asking EHOS", %{opts: opts} do
    for {argv, said} <- [
          {["graph", "office", ""], ~s("" names no deployment.)},
          {["graph", "..", @id], ~s(".." names no application.)},
          {["graph", "office", @id, "--domain", ""], ~s("" names no domain.)},
          {["graph", "office", @id, "--contract", "."], ~s("." names no contract.)},
          {["graph", "office", @id, "--process", ".."], ~s(".." names no process module.)}
        ] do
      {2, "", stderr} = ehosctl(argv, opts)
      assert stderr =~ said
    end
  end

  test "refuses more than one document at once", %{opts: opts} do
    {2, "", stderr} =
      ehosctl(["graph", "office", @id, "--domain", "Office.Domain", "--contract", "x"], opts)

    assert stderr =~ "Name one of --domain, --contract and --process"
  end

  test "a deployment or a document EHOS does not show exits with its sentence",
       %{provider: provider, opts: opts} do
    serve(provider, @not_found)
    serve(provider, "#{@path}/contract/office.billing", @not_found)

    for argv <- [
          ["graph", "office", @id],
          ["graph", "office", @id, "--contract", "office.billing"]
        ] do
      {code, "", stderr} = ehosctl(argv, opts)
      assert code != 0
      assert stderr =~ "no such deployment you may see"
    end
  end

  test "refuses an answer it cannot read, rather than print it in part",
       %{provider: provider, opts: opts} do
    for index <- [
          Map.delete(@index, "documents"),
          %{@index | "documents" => [%{"kind" => "unit", "domain" => "d", "module" => "M"}]},
          %{@index | "later_active" => 1}
        ] do
      serve(provider, {200, index})
      {1, "", stderr} = ehosctl(["graph", "office", @id], opts)
      assert stderr =~ "cannot read"
    end
  end

  test "shows text another application wrote as text, not as it is",
       %{provider: provider, opts: opts} do
    documents = [%{"kind" => "contract", "name" => "evil\e[2J", "domain" => "d", "module" => "M"}]
    serve(provider, {200, %{@index | "documents" => documents}})

    {0, stdout, ""} = ehosctl(["graph", "office", @id], opts)
    refute stdout =~ "\e[2J"
  end

  test "names the application and the deployment in the path as they are",
       %{provider: provider, opts: opts} do
    serve(provider, "/api/v1/applications/a%20b/deployments/c%2Fd/graph", {200, @index})

    {0, _stdout, ""} = ehosctl(["graph", "a b", "c/d"], opts)
  end

  test "the application and the deployment are required", %{opts: opts} do
    {code, _stdout, stderr} = ehosctl(["graph", "office"], opts)
    assert code != 0
    assert stderr =~ "DEPLOYMENT"
  end
end

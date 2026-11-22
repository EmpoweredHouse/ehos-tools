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

  @listed """
  Deployment #{@id} of office in staging, active.

   KIND      NAME              DOMAIN  MODULE
   domain    <none>            office  Office.Domain
   contract  office.invoicing  office  Office.Domain
   process   office.month_end  office  Office.Domain

  Print one with --domain and its MODULE, or --contract or --process and its NAME as the ID.
  """

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

  describe "graph" do
    test "lists the documents the deployment carried", %{provider: provider, opts: opts} do
      serve(provider, {200, @index})

      assert ehosctl(["graph", "office", @id], opts) == {0, @listed, ""}
    end

    test "says a later deployment is active there, and when nothing was carried",
         %{provider: provider, opts: opts} do
      serve(
        provider,
        {200,
         %{@index | "state" => "superseded", "later_active" => "later-id", "documents" => []}}
      )

      {0, stdout, ""} = ehosctl(["graph", "office", @id], opts)

      assert stdout == """
             Deployment #{@id} of office in staging, superseded.

             A later deployment is active there: later-id.

             This deployment carried no graph documents. A deployment carries them when its build, its bundle or its --graph options hold them.
             """
    end

    test "--json prints EHOS's answer", %{provider: provider, opts: opts} do
      serve(provider, {200, Map.put(@index, "later", "a key EHOS adds later")})

      {0, stdout, ""} = ehosctl(["graph", "office", @id, "--json"], opts)
      assert JSON.decode!(stdout) == @index
    end

    test "prints one document as JSON, asked for by its kind and its name",
         %{provider: provider, opts: opts} do
      for {option, ref, kind, printed} <- [
            {"--domain", "Office.Domain", "domain",
             """
             {
               "domain": "Office.Domain",
               "kind": "domain",
               "nodes": {
                 "command": [
                   { "id": "command:issue_invoice" }
                 ]
               },
               "relations": {},
               "schema": "eh_os_contract.graph.v1"
             }
             """},
            {"--contract", "office.invoicing", "contract",
             """
             {
               "contract": "office.invoicing",
               "kind": "contract",
               "nodes": {
                 "command": [
                   { "id": "command:issue_invoice" }
                 ]
               },
               "relations": {},
               "schema": "eh_os_contract.graph.v1"
             }
             """},
            {"--process", "office.month_end", "process",
             """
             {
               "kind": "process",
               "nodes": {
                 "command": [
                   { "id": "command:issue_invoice" }
                 ]
               },
               "process": "office.month_end",
               "relations": {},
               "schema": "eh_os_contract.graph.v1"
             }
             """}
          ] do
        document =
          @document |> Map.delete("contract") |> Map.merge(%{"kind" => kind, kind => ref})

        serve(provider, "#{@path}/#{kind}/#{ref}", {200, document})

        assert ehosctl(["graph", "office", @id, option, ref], opts) == {0, printed, ""}

        {0, stdout, ""} = ehosctl(["graph", "office", @id, option, ref, "--json"], opts)
        assert JSON.decode!(stdout) == document
      end
    end

    test "shows text another application wrote as text, not as it is",
         %{provider: provider, opts: opts} do
      documents = [
        %{"kind" => "contract", "name" => "evil\e[2J", "domain" => "d", "module" => "M"}
      ]

      serve(provider, {200, %{@index | "documents" => documents}})

      {0, stdout, ""} = ehosctl(["graph", "office", @id], opts)

      assert stdout == """
             Deployment #{@id} of office in staging, active.

              KIND      NAME         DOMAIN  MODULE
              contract  "evil\\e[2J"  d       M

             Print one with --domain and its MODULE, or --contract or --process and its NAME as the ID.
             """
    end

    test "names the application and the deployment in the path as they are",
         %{provider: provider, opts: opts} do
      serve(provider, "/api/v1/applications/a%20b/deployments/c%2Fd/graph", {200, @index})

      assert ehosctl(["graph", "a b", "c/d"], opts) == {0, @listed, ""}
    end

    test "refuses a document other than the one asked for, or none",
         %{provider: provider, opts: opts} do
      for document <- [
            %{@document | "kind" => "process"},
            %{@document | "contract" => "office.payroll"},
            %{"not" => "a graph document"}
          ] do
        serve(provider, "#{@path}/contract/office.invoicing", {200, document})

        assert ehosctl(["graph", "office", @id, "--contract", "office.invoicing"], opts) ==
                 {1, "",
                  "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
      end
    end

    test "refuses an empty name, or . or .., before asking EHOS", %{opts: opts} do
      for {argv, said} <- [
            {["graph", "office", ""],
             ~s(ehosctl does not accept "" as the name of the deployment.)},
            {["graph", "..", @id],
             ~s(ehosctl does not accept ".." as the name of the application.)},
            {["graph", "office", @id, "--domain", ""],
             ~s(ehosctl does not accept "" as the name of the domain.)},
            {["graph", "office", @id, "--contract", "."],
             ~s(ehosctl does not accept "." as the name of the contract.)},
            {["graph", "office", @id, "--process", ".."],
             ~s(ehosctl does not accept ".." as the name of the process module.)}
          ] do
        assert ehosctl(argv, opts) == {2, "", "ehosctl: #{said}\n"}
      end
    end

    test "refuses more than one document at once", %{opts: opts} do
      assert ehosctl(
               ["graph", "office", @id, "--domain", "Office.Domain", "--contract", "x"],
               opts
             ) ==
               {2, "", "ehosctl: Give only one of --domain, --contract and --process.\n"}
    end

    test "a deployment or a document EHOS does not show exits with its sentence",
         %{provider: provider, opts: opts} do
      serve(provider, @not_found)
      serve(provider, "#{@path}/contract/office.billing", @not_found)

      for argv <- [
            ["graph", "office", @id],
            ["graph", "office", @id, "--contract", "office.billing"]
          ] do
        assert ehosctl(argv, opts) ==
                 {1, "",
                  "ehosctl: That application has no such deployment you may see, or it carried " <>
                    "no such graph document.\n"}
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

        assert ehosctl(["graph", "office", @id], opts) ==
                 {1, "",
                  "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}
      end
    end

    test "the application and the deployment are required", %{opts: opts} do
      assert ehosctl(["graph", "office"], opts) ==
               {2, "",
                """
                ehosctl: missing required arguments: DEPLOYMENT

                See `ehosctl help graph`.
                """}
    end
  end

  defp serve(provider, path \\ @path, answer),
    do: FakeProvider.stub_api(provider, "GET", path, fn _ -> answer end)
end

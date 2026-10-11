defmodule Ehosctl.Verify do
  @moduledoc """
  `ehosctl verify [--no-test]`: an application checked as its CI checks it, and by EHOS (eh-os
  #355).

  In the application's directory it runs the gates the template's CI runs after `mix deps.get`,
  in that order, and stops at the first that fails:

    1. `mix format --check-formatted`
    2. `mix compile --warnings-as-errors`
    3. `mix test`, left out with `--no-test`
    4. `mix eh_os_contract.check`
    5. `mix eh_os_contract.manifest --output ehos.manifest.json`, the file CI uploads

  They run as CI runs them: under the application's own `.tool-versions`, through `mise exec`,
  with `MIX_ENV=test`, and with the terminal's own output. Dependencies are not fetched; a gate
  that needs them says so, as it does in CI.

  Then, when an installation is signed in to, EHOS checks the `ehos.yaml` and the manifest
  (`POST /api/ehos-yaml/check`, once for each; eh-os
  [`docs/ehos-yaml.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ehos-yaml.md),
  "Checking a file"). Not signed in, it says the check was left out. It submits nothing.

  It is on the governed plane, since it may talk to EHOS (eh-os D-87, "the contacting half of
  `verify`"), and chooses its installation itself, as `login` does, so it also runs without one.
  The steps are plain commands, built first and then run, so what it would do is a value a test
  can read, as `init`'s are.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Config
  alias Ehosctl.Mise
  alias Ehosctl.Refusal

  @manifest "ehos.manifest.json"

  # What EHOS takes in one request (eh-os `EhosWeb.Plugs.RawBody`): a document past it is refused
  # here, rather than read whole and sent.
  @max_bytes 1_048_576

  @type step :: %{cmd: String.t(), args: [String.t()], env: [{String.t(), String.t()}]}

  @impl Ehosctl.Command
  def name, do: :verify

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def chooses_installation?, do: true

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Check the application in this directory as its CI does, then ask EHOS to check its " <>
          "ehos.yaml and manifest when you are signed in. It submits nothing.",
      flags: [
        no_test: [
          long: "--no-test",
          help: "Leave out `mix test`, for a check without a database."
        ]
      ]
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    dir = Keyword.get_lazy(opts, :dir, &File.cwd!/0)
    runner = Keyword.get(opts, :runner, &Mise.run/3)

    with :ok <- application?(dir),
         {:ok, mise} <- found(Mise.find(opts)),
         :ok <- run_steps(steps(mise, dir, test?: not parsed.flags.no_test), runner),
         {:ok, checked} <- checked_by_ehos(dir, parsed.options[:installation], opts) do
      {:ok, %{text: checked, json: %{}}}
    end
  end

  @doc """
  The gates, as the commands that run them in the application's directory `dir`, through `mise`.
  `test?: false` leaves out `mix test`.
  """
  @spec steps(Path.t(), Path.t(), keyword()) :: [step()]
  def steps(mise, dir, opts \\ []) do
    [
      ~w(format --check-formatted),
      ~w(compile --warnings-as-errors),
      Keyword.get(opts, :test?, true) && ~w(test),
      ~w(eh_os_contract.check),
      ~w(eh_os_contract.manifest --output) ++ [@manifest]
    ]
    |> Enum.filter(& &1)
    |> Enum.map(fn gate ->
      # `mise exec` with no tool named reads the directory's `.tool-versions`, the toolchain its
      # CI installs; `MIX_ENV=test` is CI's for every gate, so the compile is the one the tests
      # use.
      %{
        cmd: mise,
        args: ["-C", dir, "exec", "--", "mix" | gate],
        env: [{"MIX_ENV", "test"}, Mise.tools_first()]
      }
    end)
  end

  defp application?(dir) do
    case Enum.reject(["mix.exs", "ehos.yaml"], &File.regular?(Path.join(dir, &1))) do
      [] ->
        :ok

      missing ->
        {:error, :invalid,
         "#{dir} is not an application's directory: it has no #{Enum.join(missing, " and no ")}. " <>
           "Run `ehosctl verify` where the application's mix.exs and ehos.yaml are."}
    end
  end

  defp found({:ok, mise}), do: {:ok, mise}
  defp found({:error, message}), do: {:error, :failed, message}

  defp run_steps(steps, runner) do
    Enum.reduce_while(steps, :ok, fn %{cmd: cmd, args: args, env: env}, :ok ->
      gate = args |> Enum.drop_while(&(&1 != "mix")) |> Enum.join(" ")
      IO.puts("==> #{gate}")

      case runner.(cmd, args, env) do
        0 ->
          {:cont, :ok}

        status ->
          {:halt, {:error, :failed, "`#{gate}` exited with #{status}; nothing after it ran."}}
      end
    end)
  end

  defp checked_by_ehos(dir, flag, opts) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    config_dir = Keyword.get_lazy(opts, :config_dir, fn -> Config.dir(env) end)

    with {:ok, config} <- Config.read(config_dir) do
      case Config.select(config, flag, env) do
        {:ok, installation} -> ask_ehos(installation, dir, opts)
        {:error, :not_signed_in, _message} when is_nil(flag) -> {:ok, left_out()}
        error -> error
      end
    end
  end

  defp left_out,
    do:
      "Every gate passed. EHOS's check of ehos.yaml and the manifest was left out: no " <>
        "installation is signed in to. Run `ehosctl login` to have it."

  defp ask_ehos(installation, dir, opts) do
    with {:ok, ehos_yaml} <- document(dir, "ehos.yaml"),
         {:ok, yaml_said} <- check(installation, "ehos.yaml", "application/yaml", ehos_yaml, opts),
         {:ok, manifest} <- document(dir, @manifest),
         {:ok, manifest_said} <-
           check(installation, @manifest, "application/json", manifest, opts) do
      {:ok, "Every gate passed.\n" <> yaml_said <> "\n" <> manifest_said}
    else
      # A sign-in that has expired or ended is one EHOS cannot be asked through: said, and left
      # out, as when there is none.
      {:error, :not_signed_in, message} ->
        {:ok, "Every gate passed. EHOS's check was left out: #{message}"}

      error ->
        error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp document(dir, file) do
    path = Path.join(dir, file)

    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_bytes ->
        {:error, :invalid, "#{file} is larger than the #{@max_bytes} bytes EHOS takes."}

      {:ok, _stat} ->
        case File.read(path) do
          {:ok, bytes} -> {:ok, bytes}
          {:error, reason} -> unreadable(file, reason)
        end

      {:error, reason} ->
        unreadable(file, reason)
    end
  end

  defp unreadable(file, reason),
    do: {:error, :failed, "#{file} cannot be read: #{:file.format_error(reason)}."}

  defp check(installation, file, type, bytes, opts) do
    case Api.answer(installation, :post, "/api/ehos-yaml/check", {:raw, type, bytes}, opts) do
      {:ok, %{status: 200, body: %{"valid" => true} = body}} ->
        {:ok, accepted(file, body)}

      {:ok, %{status: 422, body: %{"valid" => false, "errors" => errors}}} when is_list(errors) ->
        {:error, :failed, "EHOS refuses #{file}:\n" <> Enum.map_join(errors, "\n", &error/1)}

      {:ok, answer} ->
        Api.refusal(answer, installation)

      {:error, kind, message, :sent} ->
        {:error, kind, message}

      error ->
        error
    end
  end

  defp accepted("ehos.yaml", %{"version" => version, "latest" => latest})
       when is_binary(version) and is_binary(latest) and version != latest,
       do:
         "EHOS accepts ehos.yaml, as #{Refusal.shown(version)}; the newest schema is " <>
           "#{Refusal.shown(latest)}."

  defp accepted("ehos.yaml", %{"version" => version}) when is_binary(version),
    do: "EHOS accepts ehos.yaml, as #{Refusal.shown(version)}."

  defp accepted(file, %{"application" => application}) when is_binary(application),
    do: "EHOS accepts #{file}, the manifest of #{Refusal.shown(application)}."

  defp accepted(file, _body), do: "EHOS accepts #{file}."

  defp error(%{"message" => message} = error) when is_binary(message) do
    where =
      case {error["path"], error["line"]} do
        {path, line} when is_binary(path) and path != "" and is_integer(line) ->
          "#{Refusal.shown(path)} (line #{line}): "

        {path, _line} when is_binary(path) and path != "" ->
          "#{Refusal.shown(path)}: "

        {_path, line} when is_integer(line) ->
          "line #{line}: "

        _none ->
          ""
      end

    "  - " <> where <> Refusal.shown(message)
  end

  defp error(other), do: "  - " <> Refusal.shown(other)
end

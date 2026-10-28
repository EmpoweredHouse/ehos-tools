defmodule Ehosctl.Secrets do
  @moduledoc """
  `ehosctl secret list | set | rotate | delete`: an application's secrets, such as a mail
  server's password or a payment provider's key, one value per environment or as a template's
  default, through EHOS's API (eh-os
  [`docs/secrets-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/secrets-api.md),
  [D-99](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0099-the-values-of-secrets-people-supply-are-kept-in-openbao-in-the-installation-written-by-the-governance-plane-and-read-by-the-operator.md),
  [D-103](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0103-an-application-s-secrets-are-managed-through-a-capability-of-their-own-held-by-its-administrators-and-a-secret-in-use-is-not-deleted.md)),
  as the application's page in the console does.

  Each names its place with `--env` (an environment of the application) or `--template` (the
  template's default for the application, which an ephemeral environment made from it gets when
  it has no value of its own). Setting and deleting need `ehos.secret.manage` there; listing needs
  that or `ehos.application.deploy`. EHOS decides and records each call, and its refusal is printed
  in its words.

  Nobody reads a value back, and `ehosctl` never prints one. `set` reads the value from
  `--from-file`, as the file holds it, or else from standard input, a pipe or a file, less one
  line break at the end, as `echo` adds; never typed at a terminal, which would show or keep it.
  Neither is read past the 64 KiB EHOS takes. Never from an argument, which another process can read, and never in the request's
  address: the value goes in its body alone. Each `set` is a new version, and the deployments
  given the secret without a pin roll to it; `rotate` is `set` under the name of what it does.
  `delete` removes a secret with every version, asking first, and EHOS refuses it while a
  deployment that may be in force runs with it.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.Terminal

  require Ehosctl.Api

  @look "`ehosctl secret list`"
  # EHOS's bound on a value, in bytes (eh-os `docs/secrets-api.md`).
  @max_value 65_536
  # What a read takes at most: the value, the line break `echo` ends it with, and one byte to tell
  # a value too long.
  @read_bytes @max_value + 3

  @impl Ehosctl.Command
  def name, do: :secret

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec do
    place = [
      app: [
        long: "--app",
        value_name: "APPLICATION",
        required: true,
        help: "The application whose secrets these are."
      ],
      env: [
        long: "--env",
        value_name: "ENVIRONMENT",
        help: "In this environment of the application; give it or --template."
      ],
      template: [
        long: "--template",
        value_name: "TEMPLATE",
        help:
          "As this template's default for the application, which an ephemeral environment " <>
            "made from it gets when it has no value of its own; give it or --env."
      ]
    ]

    secret = [
      secret: [
        value_name: "NAME",
        required: true,
        help:
          "The secret's name, a lowercase word: smtp_password reaches a workload as SMTP_PASSWORD."
      ]
    ]

    set = fn about ->
      [
        name: nil,
        about: about,
        args: secret,
        options:
          place ++
            [
              from_file: [
                long: "--from-file",
                value_name: "PATH",
                help:
                  "Read the value from this file, as it is; without it, from standard input, " <>
                    "a pipe or a file, never a terminal."
              ]
            ],
        flags: Output.json_flag()
      ]
    end

    [
      about:
        "List, set and delete an application's secrets, one value per environment; nobody reads " <>
          "a value back.",
      subcommands: [
        list: [
          name: "list",
          about: "List an application's secrets there, each with its versions: never a value.",
          options: place,
          flags: Output.json_flag()
        ],
        set:
          Keyword.put(
            set.("Set a secret's value: a new version, the first if there was none."),
            :name,
            "set"
          ),
        rotate:
          Keyword.put(
            set.(
              "Rotate a secret: set its new value, as `set` does, and the deployments given it " <>
                "unpinned roll to it."
            ),
            :name,
            "rotate"
          ),
        delete: [
          name: "delete",
          about:
            "Delete a secret with every version; refused while a deployment that may be in " <>
              "force runs with it.",
          args: secret,
          options: place,
          flags: [yes: [long: "--yes", help: "Do not ask."]] ++ Output.json_flag()
        ]
      ]
    ]
  end

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([:list], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    app = parsed.options.app

    with :ok <- segments(parsed.options),
         {:ok, place} <- place(parsed.options),
         {:ok, %{"secrets" => secrets}} when is_list(secrets) <-
           Api.read(installation, path(app, place), opts),
         true <- Enum.all?(secrets, &secret?/1) || Api.unexpected(installation) do
      secrets = Enum.map(secrets, &listed/1)

      {:ok,
       %{
         text: table(app, place, secrets),
         json: Map.merge(%{application: app, secrets: secrets}, place_json(place))
       }}
    else
      {:ok, _body} -> Api.unexpected(installation)
      error -> error
    end
  end

  def call([command], parsed, opts) when command in [:set, :rotate] do
    %{app: app, from_file: file} = parsed.options
    name = parsed.args.secret

    with :ok <- named(name),
         :ok <- segments(parsed.options),
         {:ok, place} <- place(parsed.options),
         {:ok, value} <- value(file, name, opts),
         :ok <- fits(value) do
      Api.write(
        opts,
        {:put, path(app, place) <> "/" <> Api.segment(name), %{value: value}},
        [
          status: 200,
          key: nil,
          valid?: &(set?(&1) and &1["secret"]["name"] == name),
          only: &only_set/1,
          look: @look
        ],
        &set_said(&1, app, place)
      )
    end
  end

  def call([:delete], parsed, opts) do
    app = parsed.options.app
    name = parsed.args.secret

    with :ok <- named(name),
         :ok <- segments(parsed.options),
         {:ok, place} <- place(parsed.options),
         :ok <- confirmed(name, app, place, parsed.flags.yes) do
      Api.write(
        opts,
        {:delete, path(app, place) <> "/" <> Api.segment(name), nil},
        [
          status: 200,
          key: "secret",
          valid?: &(version?(&1) and &1["name"] == name),
          only: &Map.take(&1, ["name", "version"]),
          look: @look,
          refused: &in_use/1
        ],
        fn secret ->
          "Deleted #{Refusal.shown(secret["name"])} of #{Refusal.shown(app)} " <>
            "#{shown(place)}, with every version."
        end
      )
    end
  end

  # Exactly one place: an environment or a template.
  defp place(%{env: env, template: nil}) when is_binary(env), do: {:ok, {:environment, env}}

  defp place(%{env: nil, template: template}) when is_binary(template),
    do: {:ok, {:template, template}}

  defp place(%{env: nil, template: nil}),
    do:
      {:error, :invalid,
       "Name where: --env for an environment of the application, or --template for a " <>
         "template's default."}

  defp place(_options),
    do: {:error, :invalid, "--env and --template name two places: give one."}

  defp path(app, {kind, name}) do
    segment = if kind == :environment, do: "environments", else: "templates"
    "/api/v1/applications/#{Api.segment(app)}/#{segment}/#{Api.segment(name)}/secrets"
  end

  defp named(name) when Api.is_nameless(name),
    do: {:error, :invalid, "#{Refusal.shown(name)} names no secret."}

  defp named(_name), do: :ok

  # Each of these is a segment of the request's address: a dot segment, which a proxy may resolve,
  # would send the value to another route than the one named.
  defp segments(options) do
    case Enum.find([app: options.app, env: options.env, template: options.template], fn {_k, v} ->
           Api.is_nameless(v)
         end) do
      nil -> :ok
      {key, value} -> {:error, :invalid, "--#{key} #{Refusal.shown(value)} names nothing."}
    end
  end

  defp only_set(body) do
    %{"secret" => Map.take(body["secret"], ["name", "version"]), "rotated" => body["rotated"]}
  end

  defp shown({:environment, env}), do: "in #{Refusal.shown(env)}"
  defp shown({:template, template}), do: "as template #{Refusal.shown(template)}'s default"

  defp place_json({:environment, env}), do: %{environment: env}
  defp place_json({:template, template}), do: %{template: template}

  # The value, from the file as it is, or from a pipe or a file on standard input, less the one
  # line break `echo` ends with; never typed at a terminal (below). Neither is read past what EHOS
  # takes, so a device or a huge file is refused rather than read into memory.
  defp value(file, _name, _opts) when is_binary(file) do
    case File.open(file, [:read, :binary]) do
      {:ok, device} ->
        try do
          device |> IO.binread(@read_bytes) |> bounded()
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, :invalid, "#{Refusal.shown(file)} cannot be read: #{reason(reason)}."}
    end
  end

  # A value typed at a terminal is not read. This binary is a release without a shell, which has
  # neither `:io.get_password/0` nor a raw mode, and the terminal's own line discipline would then
  # decide what is read: it cuts or holds a long line, hands what is not read to the shell, echoes
  # whatever is typed before `stty` turns echo off, and is left without echo when the process is
  # stopped. A pipe or a file has none of that.
  defp value(nil, name, _opts) do
    if Terminal.current().input_terminal?() do
      {:error, :invalid,
       "#{Refusal.shown(name)}'s value is not typed here, so that no terminal shows or keeps it: " <>
         "give it with --from-file, or on standard input from a pipe or a file, as " <>
         "`ehosctl secret set #{Refusal.shown(name)} … < value.txt`. Nothing was set."}
    else
      with {:ok, value} <- bounded(Terminal.current().read_input(@read_bytes)),
           do: {:ok, chomp(value)}
    end
  end

  # At most what EHOS takes, and the line break `echo` adds; one byte more is a value too long.
  # Read as bytes, so that `fits/1` judges whether they are UTF-8.
  defp bounded(read) do
    case read do
      data when is_binary(data) and byte_size(data) == @read_bytes ->
        {:error, :invalid, too_long()}

      data when is_binary(data) ->
        {:ok, data}

      :eof ->
        {:ok, ""}

      {:error, reason} ->
        {:error, :invalid, "The value cannot be read: #{reason(reason)}."}
    end
  end

  defp reason(reason) when is_atom(reason), do: :file.format_error(reason)
  defp reason(reason), do: inspect(reason)

  defp too_long,
    do: "A secret's value is at most #{@max_value} bytes, and this is longer. Nothing was set."

  defp chomp(value) do
    cond do
      String.ends_with?(value, "\r\n") -> binary_part(value, 0, byte_size(value) - 2)
      String.ends_with?(value, "\n") -> binary_part(value, 0, byte_size(value) - 1)
      true -> value
    end
  end

  # EHOS refuses these too; said here, nothing is sent.
  defp fits(""),
    do:
      {:error, :invalid,
       "The value is empty: give it on standard input or with --from-file. Nothing was set."}

  defp fits(value) do
    cond do
      byte_size(value) > @max_value ->
        {:error, :invalid, too_long()}

      not String.valid?(value) ->
        {:error, :invalid, "A secret's value is UTF-8 text, and this is not. Nothing was set."}

      true ->
        :ok
    end
  end

  # A deletion is asked only when stdin and stderr are both a terminal, so a question is never
  # awaited unseen.
  defp set_said(%{"secret" => secret, "rotated" => rotated}, app, place) do
    rolled =
      case length(rotated) do
        0 -> ""
        1 -> " 1 deployment rolls to it."
        n -> " #{n} deployments roll to it."
      end

    "Set #{Refusal.shown(secret["name"])} of #{Refusal.shown(app)} #{shown(place)}: " <>
      "version #{secret["version"]}." <> rolled
  end

  # A deletion asks first, unless --yes; where nobody can answer, as in a job or a pipe, it is
  # not asked, and nothing is deleted.
  defp confirmed(_name, _app, _place, true), do: :ok

  defp confirmed(name, app, place, false) do
    question =
      "Delete #{Refusal.shown(name)} of #{Refusal.shown(app)} #{shown(place)}, with every version?"

    case confirm(question) do
      true ->
        :ok

      false ->
        {:error, :invalid, "Nothing was deleted."}

      nil ->
        {:error, :invalid,
         "Deleting #{Refusal.shown(name)} is asked first: answer on a terminal, or give --yes. " <>
           "Nothing was deleted."}
    end
  end

  # `nil` where nobody can answer: stdin and stderr are not both a terminal.
  defp confirm(question) do
    terminal = Terminal.current()

    if terminal.input_terminal?() and terminal.error_terminal?() do
      IO.write(:stderr, question <> " [y/N] ")
      yes?(terminal.gets(""))
    end
  end

  defp yes?(answer) when is_binary(answer),
    do: String.downcase(String.trim(answer)) in ["y", "yes"]

  defp yes?(nil), do: false

  # `in_use` names the deployments that run with the secret, besides EHOS's sentence.
  defp in_use(%{"error" => "in_use", "deployments" => deployments})
       when is_list(deployments) and deployments != [] do
    if Enum.all?(deployments, &is_binary/1),
      do:
        " Deployments that run with it: " <>
          Enum.map_join(deployments, ", ", &Refusal.shown/1) <> ".",
      else: nil
  end

  defp in_use(_body), do: nil

  defp secret?(%{"name" => name, "version" => version, "versions" => versions} = secret)
       when is_binary(name) and is_integer(version) and is_list(versions),
       do: nil_or_text?(secret["updated_at"]) and Enum.all?(versions, &version_entry?/1)

  defp secret?(_secret), do: false

  defp version_entry?(%{"version" => version} = entry) when is_integer(version),
    do: nil_or_text?(entry["set_by"]) and nil_or_text?(entry["set_at"])

  defp version_entry?(_entry), do: false

  defp set?(%{"secret" => secret, "rotated" => rotated}) when is_list(rotated),
    do: version?(secret) and Enum.all?(rotated, &is_binary/1)

  defp set?(_body), do: false

  defp version?(%{"name" => name, "version" => version}),
    do: is_binary(name) and is_integer(version)

  defp version?(_secret), do: false

  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  defp listed(secret) do
    secret
    |> Map.take(~w(name version updated_at versions))
    |> Map.update!("versions", fn versions ->
      Enum.map(versions, &Map.take(&1, ~w(version set_by set_at)))
    end)
  end

  defp table(app, place, []), do: "#{Refusal.shown(app)} has no secrets #{shown(place)}."

  defp table(_app, _place, secrets) do
    secrets
    |> Enum.map(fn secret ->
      newest = Enum.find(secret["versions"], &(&1["version"] == secret["version"])) || %{}

      %{
        "NAME" => Refusal.shown(secret["name"]),
        "VERSION" => Integer.to_string(secret["version"]),
        "SET BY" => Refusal.shown(newest["set_by"] || ""),
        "SET AT" => Refusal.shown(newest["set_at"] || secret["updated_at"] || "")
      }
    end)
    |> Output.table(["NAME", "VERSION", "SET BY", "SET AT"])
  end
end

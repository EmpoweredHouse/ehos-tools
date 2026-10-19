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
  `--from-file`, as the file holds it, or else from standard input, less one line break at the
  end, as `echo` adds: from a pipe to its end, or, on a terminal, with echo off up to Ctrl-D.
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

  @look "`ehosctl secret list`"
  # EHOS's bound on a value, in bytes (eh-os `docs/secrets-api.md`).
  @max_value 65_536

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
                    "asked for without echo on a terminal."
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
        {:put, path(app, place) <> "/" <> encode(name), %{value: value}},
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
         :ok <- confirmed(name, app, place, parsed.flags.yes, opts) do
      Api.write(
        opts,
        {:delete, path(app, place) <> "/" <> encode(name), nil},
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
    "/api/v1/applications/#{encode(app)}/#{segment}/#{encode(name)}/secrets"
  end

  defp encode(text), do: URI.encode(text, &URI.char_unreserved?/1)

  defp named(name) when name in ["", ".", ".."],
    do: {:error, :invalid, "#{Refusal.shown(name)} names no secret."}

  defp named(_name), do: :ok

  # Each of these is a segment of the request's address: a dot segment, which a proxy may resolve,
  # would send the value to another route than the one named.
  defp segments(options) do
    case Enum.find([app: options.app, env: options.env, template: options.template], fn {_k, v} ->
           v in ["", ".", ".."]
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

  # The value, from the file as it is, or from standard input: asked for without echo on a
  # terminal, else read to the end less the one line break `echo` ends with. Neither is read past
  # what EHOS takes, so a device or a huge file is refused rather than read into memory. `opts` may
  # replace the reading for the tests: `:terminal?`, `:ask_value` and `:read_stdin`.
  defp value(file, _name, _opts) when is_binary(file) do
    case File.open(file, [:read, :binary]) do
      {:ok, device} ->
        try do
          bounded(device)
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, :invalid,
         "#{Refusal.shown(file)} cannot be read: #{:file.format_error(reason)}."}
    end
  end

  defp value(nil, name, opts) do
    # Standard input alone decides: a terminal there is where the value is typed, so its echo is
    # turned off even when stderr, where the question goes, is redirected.
    if Keyword.get_lazy(opts, :terminal?, &stdin_terminal?/0) do
      ask = Keyword.get(opts, :ask_value, &ask_value/1)

      case ask.("#{Refusal.shown(name)}'s value (not shown; end it with Ctrl-D):") do
        value when is_binary(value) ->
          if String.contains?(value, <<3>>),
            do: {:error, :invalid, "Cancelled: nothing was set."},
            else: {:ok, chomp(value)}

        :cannot_hide ->
          {:error, :invalid,
           "This terminal cannot hide what is typed: give the value on standard input from a " <>
             "pipe, or with --from-file. Nothing was set."}

        _no_answer ->
          {:error, :invalid, "No value was typed: nothing was set."}
      end
    else
      read = Keyword.get(opts, :read_stdin, fn -> bounded(:stdio) end)

      case read.() do
        {:error, _kind, _message} = error -> error
        {:ok, value} -> {:ok, chomp(value)}
        value when is_binary(value) -> {:ok, chomp(value)}
        _eof -> {:ok, ""}
      end
    end
  end

  # At most what EHOS takes, and the line break `echo` adds; one byte more is a value too long.
  defp bounded(device) do
    case IO.binread(device, @max_value + 2) do
      data when is_binary(data) ->
        if IO.binread(device, 1) == :eof,
          do: {:ok, data},
          else: {:error, :invalid, too_long()}

      :eof ->
        {:ok, ""}

      {:error, reason} ->
        {:error, :invalid, "The value cannot be read: #{:file.format_error(reason)}."}
    end
  end

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

  # The question goes to stderr, so `--json` keeps stdout to its document. The answer is read with
  # the terminal's echo and its signals off, up to Ctrl-D, so a value of several lines is read whole
  # and none of it is left for the shell; Ctrl-C is then a character, which cancels. The terminal's
  # state is put back as it was, whatever the read gives. A release without a shell, as this
  # binary is, has neither `:io.get_password/0` nor a raw mode, and a program it runs has no
  # controlling terminal: so the terminal is named by the device `ps` says this process reads,
  # and `stty` sets it. Where it cannot, nothing is asked.
  defp ask_value(question) do
    with {:ok, device} <- terminal_device(),
         {:ok, saved} <- stty(device, ["-g"]),
         true <- Regex.match?(~r/\A[0-9A-Za-z:=]+\z/, saved),
         {:ok, _} <- stty(device, ["-echo", "-isig"]) do
      IO.write(:stderr, question <> " ")

      try do
        read_to_eof([])
      after
        stty(device, [saved])
        IO.write(:stderr, "\n")
      end
    else
      _cannot -> :cannot_hide
    end
  end

  defp read_to_eof(lines) do
    case IO.gets(:stdio, "") do
      line when is_binary(line) ->
        lines = [line | lines]

        if String.contains?(line, <<3>>) or IO.iodata_length(lines) > @max_value + 2,
          do: lines |> Enum.reverse() |> IO.iodata_to_binary(),
          else: read_to_eof(lines)

      _eof when lines == [] ->
        nil

      _eof ->
        lines |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp terminal_device do
    with {:unix, _name} <- :os.type(),
         {tty, 0} <- System.cmd("ps", ["-o", "tty=", "-p", System.pid()], stderr_to_stdout: true),
         tty = String.trim(tty),
         true <- Regex.match?(~r{\A[a-z]+[a-z0-9/]*\z}, tty) do
      {:ok, "/dev/" <> tty}
    else
      _no_terminal -> :error
    end
  rescue
    _error in ErlangError -> :error
  end

  # BSD's and macOS's stty names the device with -f, GNU's with -F.
  defp stty(device, args) do
    flag = if match?({:unix, :linux}, :os.type()), do: "-F", else: "-f"

    case System.cmd("stty", [flag, device | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      _failed -> :error
    end
  rescue
    _error in ErlangError -> :error
  end

  # A deletion is asked only when stdin and stderr are both a terminal, so a question is never
  # awaited unseen.
  defp terminal?, do: io_terminal?(:stdin) and io_terminal?(:stderr)

  defp stdin_terminal?, do: io_terminal?(:stdin)

  defp io_terminal?(stream) do
    case :io.getopts(:standard_io) do
      options when is_list(options) -> Keyword.get(options, stream) == true
      _error -> false
    end
  end

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
  # not asked, and nothing is deleted. `opts` may give `:confirm` for the tests.
  defp confirmed(_name, _app, _place, true, _opts), do: :ok

  defp confirmed(name, app, place, false, opts) do
    question =
      "Delete #{Refusal.shown(name)} of #{Refusal.shown(app)} #{shown(place)}, with every version?"

    confirm =
      Keyword.get(opts, :confirm, fn question ->
        if terminal?() do
          IO.write(:stderr, question <> " [y/N] ")
          yes?(IO.gets(:stdio, ""))
        end
      end)

    case confirm.(question) do
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

  defp yes?(answer) when is_binary(answer),
    do: String.downcase(String.trim(answer)) in ["y", "yes"]

  defp yes?(_eof), do: false

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

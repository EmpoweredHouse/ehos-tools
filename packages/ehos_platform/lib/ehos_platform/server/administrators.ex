defmodule EhosPlatform.Server.Administrators do
  @moduledoc """
  Adds, removes and lists the installation administrators of a server, each with an SSH key of
  their own and a ClusterRoleBinding of their own (eh-os D-199), behind `ehosctl server admin`.

  An administrator has a name, `[a-z][a-z0-9-]{0,30}`, an id of 8 hexadecimal digits that `add/3`
  makes, and one public key. Their Kubernetes user is `ehos-administrator:<name>:<id>`. The server
  holds the list in two places, which this module keeps together:

    * a line in `/home/ubuntu/.ssh/authorized_keys`, `<key> ehos-administrator:<name>:<id>`
      (`EhosPlatform.Server.AuthorizedKeys`);
    * a ClusterRoleBinding `ehos-administrator-<name>-<id>`, labelled
      `ehos.empowered.house/installation-administrator: <name>`, that binds the user to
      `cluster-admin`.

  The key every administrator shared before is `shared`, a name with no id and no binding. Each
  write of the file names the unnamed line that holds the provisioning key (the
  `ssh_public_key` that `up` recorded) `shared`, unless an administrator's own line holds that
  key; on GCP, where the guest agent's line holds it, it adds its own `shared` line beside it.
  `shared` does not count as an administrator: an installation keeps at least one person of
  their own once it has one, and `remove/2` refuses removing `shared` before.

  Each command works over SSH alone (`EhosPlatform.Server.connect/1`): no cloud credential and no
  `tofu apply`. It reads the server's state once, makes its plan from it as data (`plan_add/5`,
  `plan_remove/3`), and runs the plan's steps in order:

    * `{:write_keys, hash, contents}` writes the file under `flock`, only when the file still has
      the SHA-256 `hash` it had when it was read, keeps the previous file, and replaces it with a
      rename. A process on the server puts the previous file back after 60 seconds unless a new
      login with this workstation's key confirms the new one first. A plan never writes a file
      that does not hold that key;
    * `{:create, binding}`, `{:replace, bindings}` and `{:delete, bindings}` go to
      `sudo k3s kubectl create|replace|delete --request-timeout=30s -f -`, with what they change on standard input.
      A replace carries the `resourceVersion` it read, so a binding changed meanwhile is refused.

  On an installation made before eh-os D-199, the file holds the shared key unnamed and no
  binding names a person: `list/1` says so, `add/3` adds a person beside it, and nothing else
  changes until the administrators remove `shared`.
  """

  alias EhosPlatform.Failure
  alias EhosPlatform.Report
  alias EhosPlatform.Server
  alias EhosPlatform.Server.AuthorizedKeys

  @label "ehos.empowered.house/installation-administrator"
  @rbac "rbac.authorization.k8s.io"
  @marker "--- ehosctl administrators ---"
  @shared "shared"
  # The charts k3s installs with its Helm controller, whose service accounts are cluster-admin.
  @k3s_charts ["traefik", "traefik-crd"]

  # The file's SHA-256 (or `none`) on the first line and the file in base64 on the second, so that
  # no line of the file can read as a marker; then, after a marker line each, the bindings, the
  # roles and the CSRs as kubectl prints them. kubectl's own errors go to a file, so a warning
  # never lands in the JSON, and are printed only when it fails. Each kubectl call gives up after
  # 30 seconds: an API server that takes connections and never answers, as while k3s restarts,
  # would hold `up`, `tunnel` and every `admin` command for ever.
  @read_script ~S"""
  f="$HOME/.ssh/authorized_keys"
  e=$(mktemp) || exit 3
  trap 'rm -f "$e"' EXIT
  if [ -e "$f" ]; then sha256sum <"$f" | cut -d' ' -f1 && base64 -w0 <"$f" || exit 4; else echo none; fi
  for kinds in clusterrolebindings,rolebindings clusterroles,roles certificatesigningrequests; do
    printf '\n%s\n' '--- ehosctl administrators ---'
    sudo k3s kubectl get --request-timeout=30s "$kinds" --all-namespaces -o json 2>"$e" || { cat "$e"; exit 3; }
  done
  """

  # Standard input: the SHA-256 the file had when it was read (or `none`), then the new file. Under
  # the lock, the file is written only when it still has that hash: 76 when it changed, 75 when
  # the lock was not free within 2 minutes. The watchdog inherits the lock's descriptor, so the
  # lock is held until the new file is confirmed or the previous one is back. It starts before the
  # new file is put in place: a failure before then leaves nothing in place without it.
  @write_script ~S"""
  set -eu
  umask 077
  d="$HOME/.ssh"
  f="$d/authorized_keys"
  p="$d/.ehosctl-authorized_keys"
  IFS= read -r expected
  IFS= read -r token
  case "$token" in ''|*[!0-9a-f]*) exit 2;; esac
  n=$(mktemp "$p.XXXXXX")
  cat >"$n"
  exec 9>"$p.lock"
  if ! flock -w 120 9; then rm -f "$n"; exit 75; fi
  current=none
  if [ -e "$f" ]; then current=$(sha256sum <"$f" | cut -d' ' -f1); fi
  if [ "$current" != "$expected" ]; then rm -f "$n"; exit 76; fi
  if [ -e "$f" ]; then cp -p "$f" "$p.previous"; else : >"$p.previous"; fi
  chmod 600 "$n"
  : >"$p.pending.$token"
  nohup sh -c 'i=0
  while [ "$i" -lt 60 ]; do [ -e "$1.pending.$3" ] || exit 0; sleep 1; i=$((i + 1)); done
  mv "$1.pending.$3" "$1.expired.$3" 2>/dev/null || exit 0
  cp -p "$1.previous" "$1.restore" && mv -f "$1.restore" "$2"
  rm -f "$1.expired.$3"' sh "$p" "$f" "$token" </dev/null >/dev/null 2>&1 &
  mv -f "$n" "$f"
  """

  # Run over a new login with this workstation's key, given the token of its own write on standard
  # input: it fails when the watchdog put the previous file back first, and only one of the two can
  # take the pending mark. The mark is named by the token, so a late confirmation of an earlier
  # write never takes the mark of a later one.
  @confirm_script ~S"""
  IFS= read -r t
  case "$t" in ''|*[!0-9a-f]*) exit 2;; esac
  p="$HOME/.ssh/.ehosctl-authorized_keys"
  mv "$p.pending.$t" "$p.confirmed.$t" && rm -f "$p.confirmed.$t"
  """

  # Standard input: the path of one binding, then the DeleteOptions whose preconditions are the uid
  # and resourceVersion ehosctl read, so that the API server refuses to delete a binding that
  # changed since, as one that someone gave another subject.
  @delete_script ~S"""
  set -u
  IFS= read -r path
  case "$path" in /apis/rbac.authorization.k8s.io/v1/*) ;; *) exit 2;; esac
  case "$path" in *[!A-Za-z0-9._~%/:-]*) exit 2;; esac
  e=$(mktemp) || exit 3
  trap 'rm -f "$e"' EXIT
  sudo k3s kubectl delete --request-timeout=30s --raw "$path" -f - >/dev/null 2>"$e" || { cat "$e"; exit 3; }
  """

  @typedoc "What the server holds, as `read/2` read it."
  @type state :: %{
          hash: String.t(),
          keys: [AuthorizedKeys.line()],
          bindings: [map()],
          roles: [map()],
          requests: [map()]
        }

  @typedoc """
  What a plan needs besides the server's state: the key this workstation logs in with
  (`session`), the provisioning key, the provider, and whether it names the first administrator of
  a server that their `up` made (`first?`), who alone takes the key on cloud-init's line.
  """
  @type context :: %{
          session: AuthorizedKeys.key() | nil,
          provisioning: AuthorizedKeys.key() | nil,
          provider: atom() | nil,
          first?: boolean()
        }

  @typedoc "One change on the server, as the module docs describe each."
  @type step ::
          {:write_keys, String.t(), String.t()}
          | {:create, map()}
          | {:replace, [map()]}
          | {:delete, [map()]}

  @typedoc "The steps of a change, in order, and what the operator must know of its result."
  @type plan :: %{steps: [step()], warnings: [{String.t(), String.t() | nil}]}

  @doc """
  Whether `name` may name an installation administrator: 1 to 31 lowercase letters, digits and
  hyphens, starting with a letter. `shared` is reserved.

      iex> EhosPlatform.Server.Administrators.valid_name?("ada")
      true

      iex> EhosPlatform.Server.Administrators.valid_name?("shared")
      false
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name),
    do: is_binary(name) and name != @shared and name =~ ~r/\A[a-z][a-z0-9-]{0,30}\z/

  @doc """
  The Kubernetes user of the administrator `name` with `id`.

      iex> EhosPlatform.Server.Administrators.user("ada", "1a2b3c4d")
      "ehos-administrator:ada:1a2b3c4d"
  """
  @spec user(String.t(), String.t()) :: String.t()
  def user(name, id), do: AuthorizedKeys.comment(name, id)

  @doc """
  The ClusterRoleBinding that makes the administrator `name` with `id` a `cluster-admin`.
  """
  @spec binding(String.t(), String.t()) :: map()
  def binding(name, id) do
    %{
      "apiVersion" => "#{@rbac}/v1",
      "kind" => "ClusterRoleBinding",
      "metadata" => %{"name" => "ehos-administrator-#{name}-#{id}", "labels" => %{@label => name}},
      "roleRef" => %{"apiGroup" => @rbac, "kind" => "ClusterRole", "name" => "cluster-admin"},
      "subjects" => [%{"apiGroup" => @rbac, "kind" => "User", "name" => user(name, id)}]
    }
  end

  @doc """
  Adds the administrator `name`, with the one public key in the file at `public_key`, to the
  installation's server. `opts` are `EhosPlatform.Server.up/1`'s; the key in `:ssh_key` is the one
  this workstation logs in with, and must stay on the server.

  `add/3` run again for a name whose line is on the server with the same key, and whose binding
  is not, makes the binding alone: it completes an `add` that stopped between the two.
  """
  @spec add(String.t(), Path.t(), keyword()) :: Server.result()
  def add(name, public_key, opts) do
    with :ok <- addable(name),
         {:ok, key} <- read_key(public_key),
         {:ok, server, address} <- Server.connect(opts),
         {:ok, context} <- context(server),
         {:ok, state} <- read(server, address),
         {:ok, plan, id} <- plan_add(state, name, new_id(), key, context),
         :ok <- execute(server, address, plan.steps) do
      {:ok,
       %Report{
         outcome: "#{name} is an installation administrator of ehos-#{server.name}.",
         values: [
           {"Key", AuthorizedKeys.fingerprint(key)},
           {"Kubernetes user", user(name, id)},
           {"ClusterRoleBinding", "ehos-administrator-#{name}-#{id}"}
         ],
         next: [command(server, "tunnel --ssh-key PRIVATE_KEY --administrator #{name}")],
         warnings: [
           {"#{name} runs the next command on their own workstation.",
            "They need a copy of the folder of the installation, the state passphrase, and the " <>
              "private key of the public key that you gave."}
           | plan.warnings
         ]
       }}
    end
  end

  @doc """
  Removes the administrator `name`, or `shared`, from the installation's server: their user from
  every ClusterRoleBinding and RoleBinding, then their line in `authorized_keys`. `opts` are
  `EhosPlatform.Server.up/1`'s.
  """
  @spec remove(String.t(), keyword()) :: Server.result()
  def remove(name, opts) do
    with :ok <- removable(name),
         {:ok, server, address} <- Server.connect(opts),
         {:ok, context} <- context(server),
         {:ok, state} <- read(server, address),
         {:ok, plan} <- plan_remove(state, name, context),
         :ok <- execute(server, address, plan.steps) do
      {:ok,
       %Report{
         outcome: "#{name} is no longer an installation administrator of ehos-#{server.name}.",
         values: removed_values(plan.steps),
         next: [command(server, "admin list")],
         warnings: plan.warnings ++ [other_ways_in(name)]
       }}
    end
  end

  @doc """
  Lists, from the installation's server: each administrator, with their key and their binding;
  each line in `authorized_keys` that names nobody; each other subject bound to `cluster-admin`,
  or to a role that grants every verb on every resource, other than k3s's own; and the CSRs the
  cluster still lists. `opts` are `EhosPlatform.Server.up/1`'s.
  """
  @spec list(keyword()) :: Server.result()
  def list(opts) do
    with {:ok, server, address} <- Server.connect(opts),
         {:ok, state} <- read(server, address) do
      listing = listing(state)

      {:ok,
       %Report{
         outcome: listed(persons(state), server),
         values: listing_values(listing),
         warnings: listing.warnings
       }}
    end
  end

  @doc """
  Makes `name` the first installation administrator of a server that has none yet, with the key
  this workstation logs in with, and records them in `installation.json`: what `up --administrator`
  does once the first boot is done (eh-os D-199). Returns the values to report.

  `made?` says whether this `up` made the server: only then is the key on cloud-init's line this
  workstation's own. On a server made before, that key may be the one every administrator
  shares, which `first/4` refuses to give one person. Run again for the same name and key, as
  after an `up` that stopped, it completes what the run before began.
  """
  @spec first(Server.t(), String.t(), String.t(), boolean()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, Failure.message()}
  def first(server, address, name, made?) do
    with :ok <- addable(name),
         {:ok, context} <- context(server),
         {:ok, state} <- read(server, address),
         :ok <- first_allowed(state, server, name, context.session, made?),
         {:ok, steps, id} <- first_steps(state, name, context),
         :ok <- execute(server, address, steps),
         :ok <- Server.record_administrator(server, name, id) do
      {:ok, [{"Administrator", "#{name} (#{user(name, id)})"}]}
    end
  end

  # A run again after one that named the person whole has nothing to change but the record.
  defp first_steps(state, name, context) do
    case named_whole(state, name) do
      {:ok, id} ->
        {:ok, [], id}

      :incomplete ->
        with {:ok, plan, id} <-
               plan_add(state, name, new_id(), context.session, %{context | first?: true}),
             do: {:ok, plan.steps, id}
    end
  end

  defp named_whole(state, name) do
    with [%{id: id}] when is_binary(id) <-
           for(%{kind: :named, name: ^name} = line <- state.keys, do: line),
         true <- {name, id} in users(state.bindings, name) do
      {:ok, id}
    else
      _incomplete -> :incomplete
    end
  end

  # The same person again, with the same key: an earlier run that stopped.
  defp first_allowed(state, server, name, session, made?) do
    case {persons(state), made?} do
      {[], true} ->
        :ok

      {[], false} ->
        {:error,
         "ehosctl named no installation administrator, because ehos-#{server.name} was made " <>
           "before this up, and the key that you log in with can be the key that every " <>
           "administrator shares. Make a new key, add yourself with it with " <>
           "`admin add #{name} --public-key FILE`, then run `tunnel --administrator #{name}` " <>
           "with it."}

      {[^name], _made?} ->
        if Enum.any?(state.keys, &(&1.kind == :named and &1.name == name and &1.key == session)),
          do: :ok,
          else: none_yet(state, server)

      _others ->
        none_yet(state, server)
    end
  end

  @doc """
  The id of the installation administrator `name` on the server whose line holds the key this
  workstation logs in with, for `tunnel --administrator` (eh-os D-199), which records it in place
  of what a copied folder holds.
  """
  @spec identify(Server.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, Failure.message()}
  def identify(server, address, name) do
    with :ok <- addable(name),
         {:ok, context} <- context(server),
         {:ok, state} <- read(server, address) do
      state.keys
      |> Enum.find(&(&1.kind == :named and &1.name == name and &1.id != nil))
      |> identified(server, name, context.session)
    end
  end

  defp identified(%{key: key, id: id}, _server, _name, session) when key == session,
    do: {:ok, id}

  defp identified(%{}, server, name, _session),
    do:
      {:error,
       "The line of #{name} on ehos-#{server.name} holds another key than " <>
         "#{server.ssh_key}.pub. Give the private key of #{name} with `--ssh-key`."}

  defp identified(nil, server, name, _session),
    do:
      {:error,
       "ehos-#{server.name} has no installation administrator named #{name}. Ask an " <>
         "installation administrator to add you with `admin add #{name} --public-key FILE`."}

  @doc """
  The warnings `up` and `tunnel` give about the installation's administrators, or none when the
  server cannot be read: none of their own, or one alone.
  """
  @spec warnings(Server.t(), String.t()) :: [{String.t(), String.t() | nil}]
  def warnings(server, address) do
    case read(server, address) do
      {:ok, state} -> state |> listing() |> Map.fetch!(:counted)
      _unread -> []
    end
  end

  @doc """
  What the server holds, read in one SSH command: `authorized_keys` with its SHA-256, the
  bindings, the roles and the CSRs.
  """
  @spec read(Server.t(), String.t()) :: {:ok, state()} | {:error, Failure.message()}
  def read(server, address) do
    case Server.on_server(server, address, @read_script) do
      {output, 0} ->
        parse_state(output)

      {output, 255} ->
        {:error, Failure.printed("`ssh` could not reach #{address}.", "ssh", output)}

      {output, status} when is_integer(status) ->
        {:error,
         Failure.printed(
           "ehosctl could not read the administrators of ehos-#{server.name} " <>
             "(exit status #{status}).",
           "ssh",
           output
         )}

      {:error, :not_found} ->
        {:error, "`ssh` is not installed. `ehosctl doctor` says what is missing"}
    end
  end

  @doc """
  The state the read script printed, or an error when it is not in that form.
  """
  @spec parse_state(String.t()) :: {:ok, state()} | {:error, String.t()}
  def parse_state(output) do
    with [head, bindings, roles, requests] <- String.split(output, "\n#{@marker}\n"),
         [hash | rest] <- String.split(head, "\n", parts: 2),
         {:ok, keys} <- Base.decode64(Enum.join(rest)),
         true <- held?(hash, keys),
         {:ok, %{"items" => bindings}} <- Jason.decode(bindings),
         {:ok, %{"items" => roles}} <- Jason.decode(roles),
         {:ok, %{"items" => requests}} <- Jason.decode(requests) do
      {:ok,
       %{
         hash: hash,
         keys: AuthorizedKeys.parse(keys),
         bindings: bindings,
         roles: roles,
         requests: requests
       }}
    else
      _other -> {:error, "The server answered in a form that ehosctl cannot read."}
    end
  end

  # The file is the one whose hash the server gave, read whole; no file is empty.
  defp held?("none", ""), do: true

  defp held?(hash, keys),
    do:
      hash =~ ~r/\A[0-9a-f]{64}\z/ and
        hash == Base.encode16(:crypto.hash(:sha256, keys), case: :lower)

  @doc """
  The plan that adds `name` with `id` and `key`, and the id it gives them: `id`, or the one their
  line holds when it completes an earlier add.
  """
  @spec plan_add(state(), String.t(), String.t(), AuthorizedKeys.key(), context()) ::
          {:ok, plan(), String.t()} | {:error, String.t()}
  def plan_add(state, name, id, key, context) do
    lines = Enum.filter(state.keys, &(&1.kind == :named and &1.name == name))

    case {lines, users(state.bindings, name)} do
      {[], []} ->
        lines =
          state.keys
          |> Enum.reject(&(&1.kind == :unnamed and &1.key == key))
          |> Kernel.++([AuthorizedKeys.named_line(key, name, id)])
          |> named_shared(context.provisioning)

        with :ok <- key_free(state.keys, key),
             :ok <- not_unnamed(state.keys, key, context),
             {:ok, write} <- keys_written(lines, state, context),
             do: {:ok, plan([write, {:create, binding(name, id)}], state, name), id}

      {[%{key: ^key, id: earlier}], []} when is_binary(earlier) ->
        {:ok, plan([{:create, binding(name, earlier)}], state, name), earlier}

      _present ->
        {:error,
         "#{name} is an installation administrator already. To give them another key, remove " <>
           "them with `admin remove #{name}`, then add them again."}
    end
  end

  @doc "The plan that removes `name`, or `shared`, from the server."
  @spec plan_remove(state(), String.t(), context()) :: {:ok, plan()} | {:error, String.t()}
  def plan_remove(state, name, context) do
    named = Enum.filter(state.keys, &(&1.kind == :named and &1.name == name))
    # A copy of a removed key on a line that names nobody would still log in: it goes too.
    removed_keys = Enum.map(named, & &1.key)
    copies = Enum.filter(state.keys, &(&1.kind == :unnamed and &1.key in removed_keys))
    lines = named ++ copies
    bound = Enum.filter(state.bindings, &(users([&1], name) != []))
    persons = persons(state)
    left = persons -- [name]

    with :ok <- present(lines, bound, name),
         :ok <- not_last(name, persons, left),
         :ok <- not_in_metadata(lines, name, context),
         {:ok, writes} <- removed_keys(state, lines, context),
         do: {:ok, plan(binding_steps(bound, name) ++ writes, state, name, left)}
  end

  defp present([], [], name),
    do:
      {:error,
       "The server has no installation administrator named #{name}. `admin list` shows who " <>
         "is on it."}

  defp present(_lines, _bound, _name), do: :ok

  defp not_last(@shared, [], _left),
    do:
      {:error,
       "ehosctl did not remove shared, because no installation administrator has access of " <>
         "their own yet. Add one with `admin add` first."}

  defp not_last(name, [name], []) when name != @shared,
    do:
      {:error,
       "ehosctl did not remove #{name}, because #{name} is the last installation " <>
         "administrator. Add another one with `admin add` first."}

  defp not_last(_name, _persons, _left), do: :ok

  defp not_in_metadata(lines, name, %{provider: :gcp, provisioning: provisioning})
       when provisioning != nil do
    if Enum.any?(lines, &(&1.key == provisioning)),
      do:
        {:error,
         "ehosctl did not remove #{name}, because GCP's metadata holds the key of #{name}, and " <>
           "GCP's guest agent writes it back. First move the provisioning key to the key of " <>
           "another administrator with `up --provisioning-key FILE`, then remove #{name}."},
      else: :ok
  end

  defp not_in_metadata(_lines, _name, _context), do: :ok

  defp removed_keys(_state, [], _context), do: {:ok, []}

  defp removed_keys(state, lines, context) do
    with {:ok, write} <-
           (state.keys -- lines)
           |> named_shared(context.provisioning)
           |> keys_written(state, context),
         do: {:ok, [write]}
  end

  # A binding whose only subjects were the person's is deleted; one with others keeps them.
  defp binding_steps(bound, name) do
    {deleted, kept} =
      bound
      |> Enum.map(fn binding ->
        {binding, Enum.reject(binding["subjects"] || [], &person_subject?(&1, name))}
      end)
      |> Enum.split_with(fn {_binding, subjects} -> subjects == [] end)

    replace(Enum.map(kept, fn {binding, subjects} -> edited(binding, subjects) end)) ++
      delete(Enum.map(deleted, fn {binding, _none} -> reference(binding) end))
  end

  defp replace([]), do: []
  defp replace(bindings), do: [{:replace, bindings}]
  defp delete([]), do: []
  defp delete(bindings), do: [{:delete, bindings}]

  defp edited(binding, subjects) do
    binding
    |> Map.delete("status")
    |> Map.update("metadata", %{}, &Map.delete(&1, "managedFields"))
    |> Map.put("subjects", subjects)
  end

  defp reference(binding) do
    metadata =
      Map.take(binding["metadata"] || %{}, ["name", "namespace", "uid", "resourceVersion"])

    %{"apiVersion" => binding["apiVersion"], "kind" => binding["kind"], "metadata" => metadata}
  end

  defp plan(steps, state, name, left \\ nil) do
    left = left || Enum.uniq(persons(state) ++ [name])
    %{steps: steps, warnings: count_warnings(left)}
  end

  defp key_free(lines, key) do
    case Enum.find(lines, &(&1.kind == :named and &1.key == key)) do
      nil ->
        :ok

      %{name: other} ->
        {:error,
         "The key in the file is the key of #{other} on the server. Each installation " <>
           "administrator has a key of their own: give a new one."}
    end
  end

  # A key on a line that names nobody, or the provisioning key, can be the key that every
  # administrator shares: given to one person, everyone who holds it would act as them. Only the
  # first administrator of a server that their `up` made takes it, from cloud-init's line.
  defp not_unnamed(_lines, _key, %{first?: true}), do: :ok

  defp not_unnamed(lines, key, context) do
    if key == context.provisioning or
         Enum.any?(lines, &(&1.kind in [:unnamed, :agent] and &1.key == key)),
       do:
         {:error,
          "The key in the file is on the server already, on a line that names nobody, or it is " <>
            "the provisioning key: it can be the key that every administrator shares. Each " <>
            "installation administrator has a new key of their own: give a new one."},
       else: :ok
  end

  # The unnamed line with the provisioning key becomes `shared`; a guest agent's line with it gets
  # a `shared` line beside it; nothing changes when an administrator's own line holds it.
  defp named_shared(lines, nil), do: lines

  defp named_shared(lines, provisioning) do
    cond do
      Enum.any?(lines, &(&1.kind == :named and &1.key == provisioning)) ->
        lines

      # Every copy, so that `admin remove shared` removes each one.
      Enum.any?(lines, &(&1.kind == :unnamed and &1.key == provisioning)) ->
        Enum.map(lines, fn
          %{kind: :unnamed, key: ^provisioning} = line -> shared_line(line)
          line -> line
        end)

      index = Enum.find_index(lines, &(&1.kind == :agent and &1.key == provisioning)) ->
        List.insert_at(lines, index + 1, AuthorizedKeys.named_line(provisioning, @shared, nil))

      true ->
        lines
    end
  end

  # The line as it was, its options kept, with the comment that names it.
  # The line written again from what was read of it, its options kept: the blob can also be in an
  # option or in the comment, so its place in the text is not where the comment starts.
  defp shared_line(%{key: {type, blob}, options: options} = line) do
    comment = AuthorizedKeys.comment(@shared, nil)

    %{
      line
      | kind: :named,
        text: Enum.join(Enum.reject([options, type, blob, comment], &is_nil/1), " "),
        comment: comment,
        name: @shared,
        id: nil
    }
  end

  defp keys_written(lines, state, context) do
    if Enum.any?(lines, &(&1.key == context.session)) do
      {:ok, {:write_keys, state.hash, AuthorizedKeys.render(lines)}}
    else
      {:error,
       "ehosctl changed nothing, because the change removes the key that you log in with, " <>
         "#{AuthorizedKeys.fingerprint(context.session)}. Run the command from the workstation " <>
         "of another installation administrator."}
    end
  end

  @doc """
  What the server holds, for `list/1` and `ehosctl doctor`: the administrators, the lines that
  name nobody, the other subjects with every right, the lines ehosctl cannot read, which sshd may,
  the CSRs, and the warnings. `counted` is the
  warnings about how many administrators there are, which `up` and `tunnel` give too.
  """
  @spec listing(state()) :: %{
          administrators: [map()],
          unnamed: [map()],
          others: [map()],
          unreadable: [String.t()],
          requests: [map()],
          warnings: [{String.t(), String.t() | nil}],
          counted: [{String.t(), String.t() | nil}]
        }
  def listing(state) do
    names = Enum.uniq(persons(state) ++ bound_names(state) ++ shared_named(state.keys))
    administrators = Enum.map(names, &administrator(state, &1))
    counted = count_warnings(persons(state))

    %{
      administrators: administrators,
      unnamed:
        for(
          %{kind: kind} = line when kind in [:unnamed, :agent] <- state.keys,
          do: %{
            key: AuthorizedKeys.fingerprint(line.key),
            comment: line.comment,
            agent?: kind == :agent,
            options: line.options
          }
        ),
      others: others(state),
      unreadable: for(%{kind: :unreadable, text: text} <- state.keys, do: text),
      requests: Enum.map(state.requests, &request/1),
      counted: counted,
      warnings: counted ++ Enum.flat_map(names, &half_warnings(state, &1))
    }
  end

  defp shared_named(lines),
    do: for(%{kind: :named, name: @shared} <- lines, uniq: true, do: @shared)

  defp administrator(state, name) do
    lines = Enum.filter(state.keys, &(&1.kind == :named and &1.name == name))
    bindings = Enum.filter(state.bindings, &(users([&1], name) != []))

    ids =
      Enum.uniq(
        for(%{id: id} <- lines, id != nil, do: id) ++
          for({_name, id} <- users(state.bindings, name), do: id)
      )

    %{
      name: name,
      ids: ids,
      keys: Enum.map(lines, &AuthorizedKeys.fingerprint(&1.key)),
      options: for(%{options: options} <- lines, options != nil, do: options),
      bindings: Enum.map(bindings, &shown_binding/1)
    }
  end

  # A person in one place but not the other, by id: a binding for an id that no line holds, as
  # one made by hand for a certificate of its own, or a line whose binding is missing.
  defp half_warnings(_state, @shared), do: []

  defp half_warnings(state, name) do
    line_ids = for %{kind: :named, name: ^name, id: id} <- state.keys, id != nil, do: id
    bound_ids = for {^name, id} <- all_users(state.bindings), do: id

    case {line_ids, bound_ids -- line_ids} do
      {[_ | _], []} when bound_ids == [] ->
        [
          {"#{name} has a line in authorized_keys and no ClusterRoleBinding.",
           "Run `admin add #{name}` with their key to complete it, or `admin remove #{name}`."}
        ]

      {_lines, unheld} ->
        Enum.map(unheld, fn id ->
          {"A ClusterRoleBinding binds #{user(name, id)}, and no line in authorized_keys has " <>
             "that id.",
           "Remove each user of #{name} with `admin remove #{name}`, then add them again with " <>
             "`admin add`. If #{name} is the last installation administrator, add another one " <>
             "first."}
        end)
    end
  end

  defp count_warnings([]),
    do: [
      {"No installation administrator has access of their own.",
       "Add each person with `admin add`, with a new key of their own."}
    ]

  defp count_warnings([one]),
    do: [
      {"One installation administrator remains: #{one}.",
       "If #{one} loses their key, nobody can reach the server over SSH. Add a second one with " <>
         "`admin add`."}
    ]

  defp count_warnings(_two_or_more), do: []

  # The administrators by name: those with a line that holds an id. A name in a binding alone
  # reaches no server over SSH, and does not count as one, so a binding made by hand neither
  # lets the last administrator go nor hides that one remains.
  defp persons(state) do
    Enum.uniq(for %{kind: :named, name: name, id: id} <- state.keys, id != nil, do: name)
  end

  defp bound_names(state), do: Enum.uniq(for {name, _id} <- all_users(state.bindings), do: name)

  # Each administrator's user in `bindings`, as `{name, id}`, or `name`'s alone.
  defp users(bindings, name), do: Enum.filter(all_users(bindings), &match?({^name, _id}, &1))

  defp all_users(bindings) do
    for binding <- bindings,
        %{"kind" => "User", "name" => user} <- binding["subjects"] || [],
        {:ok, name, id} <- [AuthorizedKeys.named(user)],
        id != nil,
        uniq: true,
        do: {name, id}
  end

  defp person_subject?(%{"kind" => "User", "name" => user}, name),
    do: match?({:ok, ^name, _id}, AuthorizedKeys.named(user))

  defp person_subject?(_subject, _name), do: false

  # Every subject of a binding to a role with every right, other than an administrator and k3s's
  # own: `system:masters` in `cluster-admin`, and the service account `kube-system/helm-<chart>`
  # of k3s's Helm controller in the ClusterRoleBinding `helm-kube-system-<chart>`, for the charts
  # k3s ships alone: a name is anyone's to give.
  defp others(state) do
    full = full_roles(state.roles)

    for binding <- state.bindings,
        full_role?(binding, full),
        subject <- binding["subjects"] || [],
        not administrator_subject?(subject),
        not k3s_own?(binding, subject),
        do: %{binding: shown_binding(binding), subject: shown_subject(subject)}
  end

  defp full_roles(roles) do
    for role <- roles,
        Enum.any?(role["rules"] || [], &every_right?/1),
        into: MapSet.new(),
        do:
          {role["kind"], get_in(role, ["metadata", "namespace"]),
           get_in(role, ["metadata", "name"])}
  end

  defp every_right?(rule),
    do: Enum.all?(["apiGroups", "resources", "verbs"], &("*" in (rule[&1] || [])))

  defp full_role?(binding, full) do
    case binding["roleRef"] do
      %{"kind" => "ClusterRole", "name" => name} ->
        name == "cluster-admin" or MapSet.member?(full, {"ClusterRole", nil, name})

      %{"kind" => "Role", "name" => name} ->
        MapSet.member?(full, {"Role", get_in(binding, ["metadata", "namespace"]), name})

      _other ->
        false
    end
  end

  defp administrator_subject?(%{"kind" => "User", "name" => user}),
    do: match?({:ok, _name, id} when is_binary(id), AuthorizedKeys.named(user))

  defp administrator_subject?(_subject), do: false

  # Exact pairs only: a prefix would hide a binding someone names `system:…` or
  # `helm-kube-system-…` to stay out of the list.
  defp k3s_own?(%{"metadata" => %{"name" => "cluster-admin"}}, subject),
    do: subject == %{"apiGroup" => @rbac, "kind" => "Group", "name" => "system:masters"}

  defp k3s_own?(
         %{
           "kind" => "ClusterRoleBinding",
           "metadata" => %{"name" => "helm-kube-system-" <> chart}
         },
         subject
       )
       when chart in @k3s_charts,
       do:
         subject == %{
           "kind" => "ServiceAccount",
           "namespace" => "kube-system",
           "name" => "helm-" <> chart
         }

  defp k3s_own?(_binding, _subject), do: false

  defp shown_binding(%{
         "kind" => kind,
         "metadata" => %{"namespace" => namespace, "name" => name}
       }),
       do: "#{kind} #{namespace}/#{name}"

  defp shown_binding(%{"kind" => kind, "metadata" => %{"name" => name}}), do: "#{kind} #{name}"
  defp shown_binding(_binding), do: "a binding with no name"

  defp shown_subject(%{"kind" => "ServiceAccount", "namespace" => namespace, "name" => name}),
    do: "ServiceAccount #{namespace}/#{name}"

  defp shown_subject(%{"kind" => kind, "name" => name}), do: "#{kind} #{name}"
  defp shown_subject(_subject), do: "a subject with no name"

  defp request(request) do
    conditions =
      for %{"type" => type} <- get_in(request, ["status", "conditions"]) || [], do: type

    state =
      cond do
        get_in(request, ["status", "certificate"]) not in [nil, ""] -> "issued"
        "Denied" in conditions -> "denied"
        "Failed" in conditions -> "failed"
        "Approved" in conditions -> "approved"
        true -> "pending"
      end

    %{
      name: get_in(request, ["metadata", "name"]),
      user: get_in(request, ["spec", "username"]),
      signer: get_in(request, ["spec", "signerName"]),
      state: state
    }
  end

  defp listed(persons, server) do
    case length(persons) do
      0 -> "ehos-#{server.name} has no installation administrator of their own."
      1 -> "ehos-#{server.name} has 1 installation administrator."
      count -> "ehos-#{server.name} has #{count} installation administrators."
    end
  end

  defp listing_values(listing) do
    Enum.map(listing.administrators, &administrator_value/1) ++
      Enum.map(listing.unnamed, &unnamed_value/1) ++
      Enum.map(listing.others, &{"Other subject", "#{&1.subject}, in #{&1.binding}"}) ++
      Enum.map(listing.unreadable, &{"Unreadable line", &1}) ++
      Enum.map(listing.requests, &{"CSR #{&1.name}", "#{&1.state}, for #{&1.user}, #{&1.signer}"})
  end

  defp administrator_value(%{name: @shared, keys: keys} = administrator),
    do:
      {"shared",
       "the shared key #{Enum.join(keys, ", ")}, no ClusterRoleBinding" <>
         options_said(administrator.options)}

  defp administrator_value(
         %{name: name, ids: ids, keys: keys, bindings: bindings} = administrator
       ) do
    keys = if keys == [], do: "no key", else: "key #{Enum.join(keys, ", ")}"
    bindings = if bindings == [], do: "no ClusterRoleBinding", else: Enum.join(bindings, ", ")

    {name,
     "id #{Enum.join(ids, ", ")}, #{keys}, #{bindings}" <> options_said(administrator.options)}
  end

  # Options such as `cert-authority` or `command=` change what a key may do, so they are shown.
  defp options_said([]), do: ""
  defp options_said(options), do: ", with the options #{Enum.join(options, "; ")}"

  defp unnamed_value(%{agent?: true} = line), do: {"Key of GCP's agent", unnamed_said(line)}
  defp unnamed_value(line), do: {"Unnamed key", unnamed_said(line)}

  defp unnamed_said(%{options: options} = line) when is_binary(options),
    do: String.trim("#{line.key} #{line.comment}") <> ", with the options #{options}"

  defp unnamed_said(line), do: String.trim("#{line.key} #{line.comment}")

  defp removed_values(steps) do
    for step <- steps, value <- removed_value(step), do: value
  end

  defp removed_value({:delete, bindings}),
    do: Enum.map(bindings, &{"Deleted", shown_binding(&1)})

  defp removed_value({:replace, bindings}),
    do: Enum.map(bindings, &{"Subject removed from", shown_binding(&1)})

  defp removed_value({:write_keys, _hash, _contents}),
    do: [{"Line removed", "authorized_keys"}]

  defp removed_value(_step), do: []

  defp other_ways_in(name),
    do:
      {"#{name} can still have other ways in.",
       "This does not end their access to the cloud account, their copy of the state and its " <>
         "passphrase, an SSH session that is open, or access that they made while they were " <>
         "an administrator. `admin list` shows each binding to cluster-admin."}

  # Runs `steps` in order and stops at the first that fails.
  # A failure after a step that changed the server says what is already done, so that nobody reads
  # "changed nothing" while a binding is gone.
  defp execute(server, address, steps) do
    steps
    |> Enum.reduce_while([], fn step, done ->
      case run_step(server, address, step) do
        :ok -> {:cont, [step | done]}
        {:error, message} -> {:halt, {:error, done_before(message, Enum.reverse(done))}}
      end
    end)
    |> executed()
  end

  defp executed({:error, message}), do: {:error, message}
  defp executed(_done), do: :ok

  defp done_before(message, []), do: message

  defp done_before(message, done) do
    said = done |> Enum.flat_map(&removed_value/1) |> Enum.map_join(", ", &step_said/1)

    Failure.added(
      message,
      "\nBefore this, ehosctl changed the server: #{said}. Run the command again to finish."
    )
  end

  defp step_said({label, value}), do: "#{String.downcase(label)} #{value}"

  defp run_step(server, address, {:write_keys, hash, contents}) do
    server.progress.({:step, "Writing authorized_keys on ehos-#{server.name}"})

    token = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    input = hash <> "\n" <> token <> "\n" <> contents

    case Server.on_server(server, address, @write_script, input: input) do
      {_output, 0} ->
        confirm(server, address, token)

      {_output, 75} ->
        {:error,
         "ehosctl did not change authorized_keys, because another ehosctl was changing it on " <>
           "ehos-#{server.name} for 2 minutes. Run the command again."}

      {_output, 76} ->
        {:error,
         "ehosctl did not change authorized_keys, because it changed on ehos-#{server.name} " <>
           "after ehosctl read it. Run the command again."}

      result ->
        failed("ssh", "ehosctl could not write authorized_keys on ehos-#{server.name}.", result)
    end
  end

  defp run_step(server, address, {:create, binding}),
    do: kubectl(server, address, "create", binding)

  defp run_step(server, address, {:replace, bindings}),
    do: kubectl(server, address, "replace", kube_list(bindings))

  defp run_step(server, address, {:delete, bindings}) do
    Enum.reduce_while(bindings, :ok, fn binding, :ok ->
      case delete(server, address, binding) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp kube_list(items), do: %{"apiVersion" => "v1", "kind" => "List", "items" => items}

  # A new login with this workstation's key, which the server accepts only when the new file
  # holds it.
  defp confirm(server, address, token) do
    case Server.on_server(server, address, @confirm_script, fresh: true, input: token <> "\n") do
      {_output, 0} ->
        :ok

      {output, 255} ->
        {:error,
         Failure.printed(
           "The server did not take your key after the change of authorized_keys. It puts the " <>
             "previous file back within 60 seconds. Run the command again after that.",
           "ssh",
           output
         )}

      _put_back ->
        {:error,
         "The server put the previous authorized_keys back, because ehosctl did not confirm " <>
           "the new one within 60 seconds. Run the command again."}
    end
  end

  defp delete(server, address, %{"metadata" => metadata} = binding) do
    options = %{
      "apiVersion" => "v1",
      "kind" => "DeleteOptions",
      "preconditions" => Map.take(metadata, ["uid", "resourceVersion"])
    }

    input = binding_path(binding) <> "\n" <> Jason.encode!(options)

    case Server.on_server(server, address, @delete_script, input: input) do
      {_output, 0} ->
        :ok

      result ->
        failed(
          "kubectl delete",
          "kubectl delete failed on ehos-#{server.name}. If #{shown_binding(binding)} changed " <>
            "since ehosctl read it, run the command again.",
          result
        )
    end
  end

  @doc """
  The API path of `binding`, a ClusterRoleBinding or a RoleBinding, each segment escaped.

      iex> EhosPlatform.Server.Administrators.binding_path(%{
      ...>   "kind" => "RoleBinding",
      ...>   "metadata" => %{"namespace" => "apps", "name" => "team:ops"}
      ...> })
      "/apis/rbac.authorization.k8s.io/v1/namespaces/apps/rolebindings/team%3Aops"
  """
  @spec binding_path(map()) :: String.t()
  def binding_path(%{
        "kind" => "RoleBinding",
        "metadata" => %{"namespace" => ns, "name" => name}
      }),
      do: "/apis/#{@rbac}/v1/namespaces/#{segment(ns)}/rolebindings/#{segment(name)}"

  def binding_path(%{"metadata" => %{"name" => name}}),
    do: "/apis/#{@rbac}/v1/clusterrolebindings/#{segment(name)}"

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp kubectl(server, address, verb, object) do
    case Server.on_server(server, address, "sudo k3s kubectl #{verb} --request-timeout=30s -f -",
           input: Jason.encode!(object)
         ) do
      {_output, 0} ->
        :ok

      result ->
        failed("kubectl #{verb}", "kubectl #{verb} failed on ehos-#{server.name}.", result)
    end
  end

  defp failed(_program, _said, {:error, :not_found}),
    do: {:error, "`ssh` is not installed. `ehosctl doctor` says what is missing"}

  defp failed(program, said, {output, status}),
    do:
      {:error,
       Failure.printed(
         String.trim_trailing(said, ".") <> " (exit status #{status}).",
         program,
         output
       )}

  defp addable(name) do
    cond do
      name == @shared ->
        {:error,
         "shared is the name of the key that every administrator shared. Give the person a name " <>
           "of their own."}

      valid_name?(name) ->
        :ok

      true ->
        {:error,
         "#{inspect(name)} cannot name an installation administrator. A name has 1 to 31 " <>
           "lowercase letters, digits and hyphens, and starts with a letter."}
    end
  end

  defp removable(@shared), do: :ok
  defp removable(name), do: addable(name)

  # The public key in the file `add` is given, read whole and at most 16 KiB.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_key(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= 16_384 ->
        path |> File.read() |> key_read(path)

      {:ok, _other} ->
        {:error, "#{path} is not a public-key file."}

      {:error, reason} ->
        {:error, "#{path} cannot be read: #{:file.format_error(reason)}"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp key_read({:ok, contents}, path) do
    case AuthorizedKeys.public_key(contents) do
      {:ok, key} -> {:ok, key}
      {:error, message} -> {:error, "#{path}: #{message}"}
    end
  end

  defp key_read({:error, reason}, path),
    do: {:error, "#{path} cannot be read: #{:file.format_error(reason)}"}

  # The key this workstation logs in with, from the `.pub` beside its private key, and the
  # provisioning key. A listing needs neither.
  defp context(server) do
    session = server.ssh_key |> public_file() |> AuthorizedKeys.key_of()

    context = %{
      session: session,
      provisioning: provisioning(server),
      provider: server.provider,
      first?: false
    }

    if session == nil,
      do:
        {:error,
         "ehosctl needs #{server.ssh_key}.pub, the public key of the key that you log in with, " <>
           "to keep it on the server. Write it with `ssh-keygen -y -f #{server.ssh_key}`."},
      else: {:ok, context}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp public_file(path) do
    case File.read(path <> ".pub") do
      {:ok, contents} -> contents
      {:error, _reason} -> nil
    end
  end

  defp provisioning(server), do: server |> Server.provisioning_key() |> AuthorizedKeys.key_of()

  defp none_yet(state, server) do
    case persons(state) do
      [] ->
        :ok

      names ->
        {:error,
         "ehos-#{server.name} has installation administrators already: " <>
           "#{Enum.join(names, ", ")}. Ask one of them to add you with `admin add`."}
    end
  end

  defp new_id, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp command(server, args) do
    named = if server.name_in_commands, do: " #{server.name_option} #{server.name}", else: ""
    "#{server.command} #{args}#{named}"
  end
end

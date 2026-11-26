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
  `tofu apply`. It reads the server's state, makes its plan from it as data (`plan_add/5`,
  `plan_remove/3`), and runs the plan's steps in order. A plan writes `authorized_keys`, if at all,
  in its first step. When that write finds the file changed since it was read, as GCP's guest agent
  changes it, the command reads the server again and plans again, up to 3 times, as long as each
  administrator's line is as it was in the first read:

    * `{:write_keys, hash, contents}` writes the file under `flock`, only when the file still has
      the SHA-256 `hash` it had when it was read, keeps the previous file, and replaces it with a
      rename. A process on the server puts the previous file back after 60 seconds unless a new
      login with this workstation's key confirms the new one first. The confirmation also checks
      that the file still has the SHA-256 of what was written. When it does not, the command reads
      the file again: it goes on when each administrator's line is as written, and reads and plans
      again, within the same 3 attempts, when it is not. A plan never writes a file that does not
      hold that key;
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
  alias EhosPlatform.Server.ClientCa
  alias EhosPlatform.Shell

  @label "ehos.empowered.house/installation-administrator"
  @rbac "rbac.authorization.k8s.io"
  @marker "--- ehosctl administrators ---"
  @shared "shared"
  # How many times `add/3`, `remove/2` and `up`'s first administrator read the server and plan, and
  # how long they wait between two, when the file changed under the write.
  @attempts 3
  @pause 2_000
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

  # Run over a new login with this workstation's key, given the token of its own write and the
  # SHA-256 of the file it wrote on standard input: it fails when the watchdog put the previous file
  # back first, and only one of the two can take the pending mark. The mark is named by the token,
  # so a late confirmation of an earlier write never takes the mark of a later one. Once it holds
  # the mark, so that the watchdog never puts the previous file over another program's, it exits 77
  # when the file is no longer the one written: GCP's guest agent, which takes no lock, can write
  # back what it read before (eh-os#1836).
  @confirm_script ~S"""
  IFS= read -r t
  IFS= read -r h
  case "$t" in ''|*[!0-9a-f]*) exit 2;; esac
  case "$h" in ''|*[!0-9a-f]*) exit 2;; esac
  p="$HOME/.ssh/.ehosctl-authorized_keys"
  mv "$p.pending.$t" "$p.confirmed.$t" || exit 1
  rm -f "$p.confirmed.$t"
  c=$(sha256sum <"$HOME/.ssh/authorized_keys" | cut -d' ' -f1) || exit 1
  [ "$c" = "$h" ] || exit 77
  """

  # On GCP, the attributes of the instance's and the project's metadata that GCP's guest agent
  # reads SSH keys from, from the metadata server, which answers the instance without a
  # credential: a line each, the attribute and its value in base64, or `-` when it is not set.
  # Only these attributes are read: others, such as the user data, can hold secrets. Then the
  # authorized_keys of each user but ubuntu, `home/<user>`, where the agent writes a key in the
  # metadata for that user, whom it makes a sudoer, and keeps it until its next run. The lines are
  # printed only once every attribute is read, so that a failure, whose output ehosctl prints,
  # shows none of the keys' comments, which can be people's email addresses. No proxy: the
  # metadata server is reached on the instance alone.
  @metadata_attributes ~w(instance/attributes/ssh-keys instance/attributes/sshKeys
                          instance/attributes/block-project-ssh-keys project/attributes/ssh-keys
                          project/attributes/sshKeys)
  @metadata_script String.replace(
                     ~S"""
                     m=http://169.254.169.254/computeMetadata/v1
                     o=$(mktemp) && r=$(mktemp) || exit 3
                     trap 'rm -f "$o" "$r"' EXIT
                     for a in ATTRIBUTES; do
                       c=$(curl -sS --noproxy '*' --max-time 10 -H 'Metadata-Flavor: Google' -o "$o" -w '%{http_code}' "$m/$a") || exit 4
                       case "$c" in
                         200) v=$(base64 -w0 <"$o") || exit 4; printf '%s %s\n' "$a" "$v" >>"$r" ;;
                         404) printf '%s -\n' "$a" >>"$r" ;;
                         *) echo "The metadata server answered $c for $a."; exit 5 ;;
                       esac
                     done
                     sudo -n sh -c 'for f in /home/*/.ssh/authorized_keys; do
                       u=${f#/home/}; u=${u%%/*}
                       if [ "$u" = ubuntu ] || [ ! -f "$f" ]; then continue; fi
                       v=$(base64 -w0 <"$f") || exit 6
                       printf "home/%s %s\n" "$u" "$v"
                     done' >>"$r" || exit 6
                     cat "$r"
                     """,
                     "ATTRIBUTES",
                     Enum.join(@metadata_attributes, " ")
                   )

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
  (`session`), the provisioning key, the provider, whether it names the first administrator of
  a server that their `up` made (`first?`), who alone takes the key on cloud-init's line, and the
  values of GCP's metadata that GCP's guest agent reads SSH keys from (`metadata`), as `remove/2`
  reads them on GCP, each with where it is: `:instance` or `:project`, or `{:unread, message, advice}`
  when it could not read them.
  """
  @type context :: %{
          session: AuthorizedKeys.key() | nil,
          provisioning: AuthorizedKeys.key() | nil,
          provider: atom() | nil,
          first?: boolean(),
          metadata:
            [{:instance | :project, String.t()}] | {:unread, Failure.message(), String.t()}
        }

  @typedoc "One change on the server, as the module docs describe each."
  @type step ::
          {:write_keys, String.t(), String.t()}
          | {:create, map()}
          | {:replace, [map()]}
          | {:delete, [map()]}

  @typedoc """
  The steps of a change, in order, and what the operator must know of its result. A plan that
  removes a person also holds the keys it removes (`removed`), and why the removal cannot hold yet
  (`pending`), or `nil`.
  """
  @type plan :: %{
          required(:steps) => [step()],
          required(:warnings) => [{String.t(), String.t() | nil}],
          optional(:removed) => [AuthorizedKeys.key()],
          optional(:pending) =>
            nil
            | :agent
            | {:metadata, [{:instance | :project | :home, String.t()}]}
            | {:unread, Failure.message(), String.t()}
        }

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
  The name of an installation administrator made from `user`, a user name on a workstation, for
  `up`'s first administrator when nobody gives one: in lowercase, each character other than a
  letter, a digit or a hyphen a hyphen, one hyphen for several, from the first letter on, and at
  most 31 characters with no hyphen at the end. `:error` when that is no name `valid_name?/1`
  accepts.

      iex> EhosPlatform.Server.Administrators.default_name("Ada.Lovelace")
      {:ok, "ada-lovelace"}

      iex> EhosPlatform.Server.Administrators.default_name("2nd_user")
      {:ok, "nd-user"}

      iex> EhosPlatform.Server.Administrators.default_name("Zoë  Ng")
      {:ok, "zo-ng"}

      iex> EhosPlatform.Server.Administrators.default_name(String.duplicate("a", 30) <> "-b")
      {:ok, String.duplicate("a", 30)}

      iex> EhosPlatform.Server.Administrators.default_name("Shared")
      :error

      iex> EhosPlatform.Server.Administrators.default_name("1001")
      :error

      iex> EhosPlatform.Server.Administrators.default_name(<<0xFF, ?a>>)
      :error
  """
  @spec default_name(String.t()) :: {:ok, String.t()} | :error
  def default_name(user) when is_binary(user) do
    if String.valid?(user), do: user |> normalised() |> named(), else: :error
  end

  defp normalised(user) do
    user
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/u, "-")
    |> String.replace(~r/-+/, "-")
    |> String.replace(~r/\A[^a-z]+/, "")
    |> String.slice(0, 31)
    |> String.trim_trailing("-")
  end

  defp named(name), do: if(valid_name?(name), do: {:ok, name}, else: :error)

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
         id = new_id(),
         {:ok, plan, id} <- change(server, address, &plan_add(&1, name, id, key, context)) do
      {:ok,
       %Report{
         outcome: "#{name} is an installation administrator of ehos-#{server.name}.",
         values: [
           {"Key", AuthorizedKeys.fingerprint(key)},
           {"Kubernetes user", user(name, id)},
           {"ClusterRoleBinding", "ehos-administrator-#{name}-#{id}"}
         ],
         next: [command(server, "tunnel --ssh-key PRIVATE_KEY")],
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
  Removes the administrator `name`, or `shared`, from the installation's server: their line in
  `authorized_keys`, then their user from every ClusterRoleBinding and RoleBinding. The line goes
  first because the cluster's API is reached through an SSH tunnel: a failure between the two
  leaves a binding that the removed key can use through a tunnel still open, or that another key
  the server accepts, such as `shared`, can reach, never the key on the server with the binding
  gone.

  On GCP, GCP's guest agent puts each key in the metadata of the instance and of the project on
  the server, for any user, whatever ehosctl writes. So `remove/2` first reads that metadata from
  the server. When the metadata or a line of the agent holds a key of the person, or the metadata
  cannot be read, it removes what it can, leaves a comment with the key in `authorized_keys`, and
  fails, saying what to do: a run again then reads the comment, and finishes once the key can no
  longer come back. When nothing can put the key back, it reads `authorized_keys` once more, 2
  seconds after the bindings, and fails when a key of the person is back on a line.
  `opts` are `EhosPlatform.Server.up/1`'s.
  """
  @spec remove(String.t(), keyword()) :: Server.result()
  def remove(name, opts) do
    with :ok <- removable(name),
         {:ok, server, address} <- Server.connect(opts),
         {:ok, context} <- context(server),
         {:ok, context} <- with_metadata(context, server, address),
         {:ok, plan} <- change(server, address, &plan_remove(&1, name, context)),
         :ok <- finished(server, address, name, plan) do
      {:ok,
       %Report{
         outcome: "#{name} is no longer an installation administrator of ehos-#{server.name}.",
         values: removed_values(plan.steps),
         next: [command(server, "admin list")],
         warnings: plan.warnings ++ [other_ways_in(name)]
       }}
    end
  end

  # The removal holds only when nothing puts the key back (ehos-tools#1157): ehosctl changes no
  # metadata, so the person who removes it there runs the command again, which then finishes.
  defp finished(server, address, name, %{pending: nil} = plan),
    do: still_removed(server, address, name, plan)

  defp finished(server, _address, name, %{pending: reason} = plan) do
    message = pending_said(reason, name, server)

    {:error,
     case plan.steps do
       [] -> Failure.added(message, " Then run the command again.")
       steps -> done_before(message, steps)
     end}
  end

  defp pending_said({:metadata, holders}, name, server) do
    "GCP's guest agent can put the key of #{name} on ehos-#{server.name}. " <>
      Enum.map_join(holders, " ", &holder_said/1) <>
      " #{name} can still log in over SSH. " <> holders_step(holders)
  end

  # The metadata no longer holds the key, as when someone removed it and the agent has not run
  # since: the agent's line still logs the person in.
  defp pending_said(:agent, name, server),
    do:
      "A line of GCP's guest agent in authorized_keys on ehos-#{server.name} holds the key of " <>
        "#{name}, and the metadata that ehosctl read does not. #{name} can still log in over " <>
        "SSH. Wait until the agent removes its line, or make sure that the agent runs."

  defp pending_said({:unread, message, advice}, name, _server) do
    Failure.added(
      message,
      " So GCP's guest agent can put the key of #{name} back, and #{name} can still log in " <>
        "over SSH." <> advice
    )
  end

  defp holder_said({:home, user}),
    do: "The authorized_keys of #{user_said(user)} on the server holds it, with sudo."

  defp holder_said({place, user}),
    do: "The metadata of the #{place} in GCP holds it, for #{user_said(user)}."

  # The agent removes a user's key on its next run once the metadata no longer holds it.
  defp holders_step(holders) do
    if Enum.all?(holders, &match?({:home, _user}, &1)),
      do: "Wait until the agent removes that key, or make sure that the agent runs.",
      else: "Remove the key from the metadata in GCP."
  end

  # A user name from the metadata, shown only in the form Linux takes: anyone with access to the
  # metadata writes it.
  defp user_said(user) do
    if Regex.match?(~r/\A[a-z_][a-z0-9_.-]{0,31}\z/i, user),
      do: "the user #{user}",
      else: "a user"
  end

  # GCP's guest agent takes no lock, and can write back the file it read before ehosctl's write
  # after the confirmation too (ehos-tools#1155), or write a key put in the metadata for `ubuntu`
  # meanwhile. So on GCP a remove that wrote the file reads it once more, after a pause for the
  # agent's run, and fails when a removed key is back on a line sshd reads.
  defp still_removed(
         %{provider: :gcp} = server,
         address,
         name,
         %{steps: [{:write_keys, _hash, _contents} | _bindings]} = plan
       ) do
    server.clock.sleep(@pause)

    case read(server, address) do
      {:ok, state} -> keys_gone(state, server, name, plan)
      {:error, message} -> {:error, done_before(message, plan.steps)}
    end
  end

  defp still_removed(_server, _address, _name, _plan), do: :ok

  defp keys_gone(state, server, name, plan) do
    state.keys
    |> Enum.filter(&(sshd_reads?(&1) and holds_removed?(&1, plan.removed)))
    |> Enum.map(& &1.kind)
    |> back(server, name, plan)
  end

  defp back([], _server, _name, _plan), do: :ok

  defp back(kinds, server, name, plan) do
    said =
      "A key of #{name} is in authorized_keys on ehos-#{server.name} again after ehosctl " <>
        "removed it, so #{name} can still log in over SSH. " <> back_said(kinds, name, server)

    {:error, back_done(said, :named in kinds, plan.steps)}
  end

  # A run again finishes only from a named line: no other line records whose key it is.
  defp back_done(said, true, steps), do: done_before(said, steps)

  defp back_done(said, false, steps),
    do:
      said <>
        "\nBefore this, ehosctl changed the server: " <>
        Enum.map_join(steps, ", ", &done_said/1) <> "."

  defp back_said(kinds, name, server) do
    cond do
      :named in kinds ->
        "GCP's guest agent, or another program, wrote the file back."

      :agent in kinds ->
        "GCP's guest agent wrote it, from the metadata in GCP. Remove the key from the " <>
          "metadata of the instance or of the project. The agent then removes its line."

      true ->
        "Another program wrote it. Remove its line from authorized_keys on " <>
          "ehos-#{server.name}, as `admin list` shows it, before #{name} uses it."
    end
  end

  # sshd reads no comment, and no blank line.
  defp sshd_reads?(line), do: line.kind not in [:other, :removed]

  # By the blob in the line's text, so that a line in a form ehosctl does not read counts too.
  defp holds_removed?(line, removed),
    do: Enum.any?(removed, fn {_type, blob} -> String.contains?(line.text, blob) end)

  @doc """
  Lists, from the installation's server: each administrator, with their key and their binding;
  each line in `authorized_keys` that names nobody; each other subject bound to `cluster-admin`,
  or to a role that grants every verb on every resource, other than k3s's own; and the CSRs the
  cluster still lists. It warns, as `EhosPlatform.Server.ClientCa.warnings/2` says, about a
  rotation of the client CA that runs or did not end: EHOS at zero replicas, a copy of k3s's keys on
  the disk. It says so also when it cannot read the administrators, as while k3s is stopped.
  `opts` are `EhosPlatform.Server.up/1`'s.
  """
  @spec list(keyword()) :: Server.result()
  def list(opts) do
    with {:ok, server, address} <- Server.connect(opts) do
      rotation = ClientCa.warnings(ClientCa.status(server, address), server)

      server
      |> read(address)
      |> listed_with(rotation, server)
    end
  end

  defp listed_with({:ok, state}, rotation, server) do
    listing = listing(state)

    {:ok,
     %Report{
       outcome: listed(persons(state), server),
       values: listing_values(listing),
       warnings: listing.warnings ++ rotation
     }}
  end

  defp listed_with({:error, message}, rotation, _server),
    do: {:error, Failure.added(message, Enum.map_join(rotation, &warning_said/1))}

  defp warning_said({head, nil}), do: "\n" <> head
  defp warning_said({head, explanation}), do: "\n" <> head <> " " <> explanation

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
    with {:ok, state, context} <- read_first(server, address, name),
         :ok <- first_allowed(state, server, name, context.session, made?),
         do: name_first(server, address, state, name, context)
  end

  @doc """
  Makes `name`, the name `default_name/1` made from the user name on this workstation, the first
  installation administrator of a server that this `up` made, as `first/4` does. It names nobody,
  and returns no values, when the server has an administrator of their own already, other than
  `name` with this workstation's key: a name nobody gave is no reason to refuse.
  """
  @spec first_by_default(Server.t(), String.t(), String.t()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, Failure.message()}
  def first_by_default(server, address, name) do
    with {:ok, state, context} <- read_first(server, address, name) do
      state
      |> first_allowed(server, name, context.session, true)
      |> by_default(server, address, state, name, context)
    end
  end

  defp by_default(:ok, server, address, state, name, context),
    do: name_first(server, address, state, name, context)

  defp by_default({:error, _someone_named}, _server, _address, _state, _name, _context),
    do: {:ok, []}

  defp read_first(server, address, name) do
    with :ok <- addable(name),
         {:ok, context} <- context(server),
         {:ok, state} <- read(server, address),
         do: {:ok, state, context}
  end

  # Through `change/4`, as `add/3`, from the state that `first_allowed/5` checked: GCP's guest agent
  # is busiest at the first boot (eh-os#1836).
  defp name_first(server, address, state, name, context) do
    id = new_id()

    with {:ok, _plan, id} <-
           change(server, address, &first_plan(&1, name, id, context), state),
         :ok <- Server.record_administrator(server, name, id) do
      {:ok, [{"Administrator", "#{name} (#{user(name, id)})"}]}
    end
  end

  # A run again after one that named the person whole has nothing to change but the record.
  defp first_plan(state, name, id, context) do
    case named_whole(state, name) do
      {:ok, earlier} ->
        {:ok, %{steps: [], warnings: []}, earlier}

      :incomplete ->
        plan_add(state, name, id, context.session, %{context | first?: true})
    end
  end

  defp named_whole(state, name) do
    with [%{id: id}] when is_binary(id) <-
           for(%{kind: :named, name: ^name} = line <- state.keys, do: line),
         true <- {name, id} in granted(state.bindings, name) do
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
           "`admin add #{name} --public-key FILE`, then run " <>
           "`tunnel --ssh-key PRIVATE_KEY` with the private key of that key."}

      {[^name], _made?} ->
        if Enum.any?(state.keys, &(&1.kind == :named and &1.name == name and &1.key == session)),
          do: :ok,
          else: none_yet(state, server)

      _others ->
        none_yet(state, server)
    end
  end

  @doc """
  The installation administrator this workstation acts as, `{name, id, fingerprint}`, from `state`
  as `read/2` gives it: the person whose line holds the key this workstation logs in with, and the
  fingerprint of that key, for `tunnel`
  (eh-os D-199), which records them in place of what a copied folder holds. `nil` when no
  person's line holds that key, while the server still has the key that every administrator
  shares: a `shared` line, or the provisioning key on a line that names nobody while no person's
  line holds it, or no person at all, as on an installation not moved yet, or a new one whose
  `up` named nobody. Then `tunnel` copies k3s's admin file. Otherwise a key on no person's line
  is refused, so that `tunnel` does not copy that admin file from a server that every person
  reaches with a key of their own.

  With `name`, as `tunnel --administrator` gives it, the line of `name` must hold that key.
  """
  @spec acting(Server.t(), state(), String.t() | nil) ::
          {:ok, {String.t(), String.t(), String.t()} | nil} | {:error, Failure.message()}
  def acting(server, state, nil) do
    with {:ok, session} <- session(server) do
      state.keys
      |> Enum.filter(&(person_line?(&1) and &1.key == session))
      |> held_by(server, state)
    end
  end

  def acting(server, state, name) do
    with :ok <- addable(name),
         {:ok, session} <- session(server) do
      state.keys
      |> Enum.find(&(person_line?(&1) and &1.name == name))
      |> identified(server, name, session)
    end
  end

  defp person_line?(line), do: line.kind == :named and line.id != nil

  defp held_by([], server, state),
    do: until_moved(shared_kept?(state, provisioning(server)), server)

  defp held_by([%{name: name, id: id, key: key}], _server, _state),
    do: {:ok, {name, id, AuthorizedKeys.fingerprint(key)}}

  # `admin add` refuses a key that a person holds already: only a hand-written file has two.
  defp held_by(lines, server, _state) do
    {last, others} = lines |> Enum.map(& &1.name) |> List.pop_at(-1)

    {:error,
     "On ehos-#{server.name}, the lines of #{Enum.join(others, ", ")} and #{last} hold " <>
       "#{server.ssh_key}.pub, the key that you log in with, so ehosctl cannot tell which " <>
       "installation administrator you are. Run the command again with `--administrator NAME`. " <>
       "Ask an installation administrator to give each person a key of their own."}
  end

  @doc """
  Whether the server in `state` still keeps the key that every administrator shares, given the
  `provisioning` key: a line named `shared`, the provisioning key on cloud-init's or GCP's
  agent's line while no person's line holds it, or no person with a line at all, whose server any
  key that logs in reaches. On GCP the agent's line keeps the provisioning key once it is a
  person's, which is not the shared key.
  """
  @spec shared_kept?(state(), AuthorizedKeys.key() | nil) :: boolean()
  def shared_kept?(state, provisioning) do
    Enum.any?(state.keys, &(&1.kind == :named and &1.name == @shared)) or
      not Enum.any?(state.keys, &person_line?/1) or
      unnamed_provisioning?(state.keys, provisioning)
  end

  @doc """
  The provisioning key that `up` recorded for `server`, as a key, or `nil`.
  """
  @spec provisioning(Server.t()) :: AuthorizedKeys.key() | nil
  def provisioning(server), do: server |> Server.provisioning_key() |> AuthorizedKeys.key_of()

  defp unnamed_provisioning?(_keys, nil), do: false

  defp unnamed_provisioning?(keys, provisioning) do
    Enum.any?(keys, &(&1.kind in [:unnamed, :agent] and &1.key == provisioning)) and
      not Enum.any?(keys, &(person_line?(&1) and &1.key == provisioning))
  end

  defp until_moved(true, _server), do: {:ok, nil}

  defp until_moved(false, server),
    do:
      {:error,
       "No line of an installation administrator on ehos-#{server.name} holds " <>
         "#{server.ssh_key}.pub, the key that you log in with. ehosctl finds no key on the " <>
         "server that every administrator shares, so it does not copy the admin file of k3s. " <>
         "Ask an installation administrator to add you with " <>
         "`#{command(server, "admin add NAME --public-key FILE")}`. Then run " <>
         "`#{command(server, "tunnel --ssh-key PRIVATE_KEY")}` with the private key of the " <>
         "key that they add."}

  defp identified(%{key: key, id: id}, _server, name, session) when key == session,
    do: {:ok, {name, id, AuthorizedKeys.fingerprint(key)}}

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

    case {lines, granted(state.bindings, name)} do
      {[], []} ->
        lines =
          state.keys
          |> Enum.reject(&(&1.kind == :unnamed and &1.key == key))
          |> Kernel.++([AuthorizedKeys.named_line(key, name, id)])
          |> named_shared(context.provisioning)

        with :ok <- not_unfinished(state.keys, name),
             :ok <- key_free(state.keys, key),
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

  @doc """
  The plan that removes `name`, or `shared`, from the server: their lines, each copy of their keys
  on a line that names nobody or that ehosctl cannot read, and their user in each binding. It
  gives the keys it removes (`removed`), and why the removal cannot hold yet (`pending`), or `nil`:
  GCP's guest agent can put a key back, as the metadata in `context` says (see `remove/2`). Then
  the file keeps a comment for each key, which a plan for the same name reads again.
  """
  @spec plan_remove(state(), String.t(), context()) :: {:ok, plan()} | {:error, String.t()}
  def plan_remove(state, name, context) do
    named = Enum.filter(state.keys, &(&1.kind == :named and &1.name == name))
    marked = Enum.filter(state.keys, &(&1.kind == :removed and &1.name == name))
    removed = Enum.uniq(Enum.map(named ++ marked, & &1.key))
    # A copy of a removed key on a line that names nobody, or that sshd may read and ehosctl
    # cannot, would still log in: it goes too.
    copies =
      Enum.filter(
        state.keys,
        &((&1.kind == :unnamed and &1.key in removed) or
            (&1.kind == :unreadable and holds_removed?(&1, removed)))
      )

    bound = Enum.filter(state.bindings, &(users([&1], name) != []))
    persons = persons(state)
    left = persons -- [name]
    pending = put_back(removed, state, context)

    with :ok <- present(named ++ copies ++ marked, bound, name),
         :ok <- not_last(name, persons, left),
         :ok <- not_in_metadata(named ++ copies, name, context),
         {:ok, writes} <- removed_lines(state, named ++ copies, marked, pending, context) do
      plan = plan(writes ++ binding_steps(bound, name), state, name, left)
      {:ok, Map.merge(plan, %{removed: removed, pending: pending})}
    end
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

  # Why a key of the person can come back (ehos-tools#1157): GCP's guest agent puts each key in
  # GCP's metadata on the server, for any user, whom it makes a sudoer, and keeps its own line for
  # a while. By the blob in the metadata's text, as for the lines of the file: a line of the
  # metadata in a form ehosctl does not read, such as one with a CRLF ending, can be one the agent
  # writes.
  defp put_back([], _state, _context), do: nil

  defp put_back(removed, state, context) do
    agent? = Enum.any?(state.keys, &(&1.kind == :agent and holds_removed?(&1, removed)))
    put_back_by(context.metadata, holders(context.metadata, removed), agent?)
  end

  defp put_back_by({:unread, _message, _advice} = unread, _holders, _agent?), do: unread
  defp put_back_by(_metadata, [], true), do: :agent
  defp put_back_by(_metadata, [], false), do: nil
  defp put_back_by(_metadata, holders, _agent?), do: {:metadata, holders}

  defp holders({:unread, _message, _advice}, _removed), do: []

  defp holders(metadata, removed) do
    for {place, value} <- metadata,
        line <- String.split(value, "\n"),
        Enum.any?(removed, fn {_type, blob} -> String.contains?(line, blob) end),
        uniq: true,
        do: {place, line |> String.split(":", parts: 2) |> hd() |> String.trim()}
  end

  # Read once, before the first plan. Metadata that cannot be read is a reason of its own: ehosctl
  # cannot tell then whether the agent puts the person's key back.
  defp with_metadata(%{provider: :gcp} = context, server, address) do
    case Server.on_server(server, address, @metadata_script) do
      {output, 0} ->
        {:ok, %{context | metadata: metadata_read(parse_metadata(output), server)}}

      {output, status} when is_integer(status) ->
        {:ok,
         %{
           context
           | metadata:
               {:unread,
                Failure.printed(
                  "ehosctl could not read the SSH keys in the metadata of ehos-#{server.name} " <>
                    "in GCP (exit status #{status}).",
                  "ssh",
                  unread_output(output)
                ),
                " Make sure that curl and base64 run on the server, and that the metadata " <>
                  "server of GCP answers there."}
         }}

      {:error, :not_found} = result ->
        failed("ssh", "", result)
    end
  end

  defp with_metadata(context, _server, _address), do: {:ok, context}

  defp metadata_read({:ok, metadata}, _server), do: metadata

  defp metadata_read(:error, server),
    do:
      {:unread,
       "The metadata server of ehos-#{server.name} answered in a form that ehosctl cannot read.",
       " Check the values ssh-keys and sshKeys in the metadata of the instance and of the " <>
         "project in GCP."}

  # A failure can come while the script prints what it read, as when the connection ends: its
  # lines, whose comments can be people's email addresses, are left out.
  defp unread_output(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, ["home/" | @metadata_attributes]))
    |> Enum.join("\n")
  end

  @doc ~S"""
  The values of GCP's metadata that GCP's guest agent reads SSH keys from, each with where it is,
  from what the metadata script printed: the instance's `ssh-keys` and `sshKeys`, and the
  project's unless the instance's `block-project-ssh-keys` is true as Go's `strconv.ParseBool`
  reads it, which the agent uses. A value holds a line `user:key` for each key, for any user: the
  agent makes each user, and every user it makes is a sudoer. Then, as `:home`, the
  `authorized_keys` of each user but ubuntu, in the same form. `:error` when the output is not in
  that form.

      iex> keys = "ubuntu:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEB ubuntu"
      iex> EhosPlatform.Server.Administrators.parse_metadata(
      ...>   "instance/attributes/ssh-keys #{Base.encode64(keys)}\n" <>
      ...>     "instance/attributes/sshKeys -\ninstance/attributes/block-project-ssh-keys -\n" <>
      ...>     "project/attributes/ssh-keys #{Base.encode64("bob:ssh-ed25519 AAAAC3Nz bob")}\n" <>
      ...>     "project/attributes/sshKeys -\n"
      ...> )
      {:ok, [{:instance, keys}, {:project, "bob:ssh-ed25519 AAAAC3Nz bob"}]}
  """
  @spec parse_metadata(String.t()) ::
          {:ok, [{:instance | :project | :home, String.t()}]} | :error
  def parse_metadata(output) do
    with {:ok, read} <- attributes(output), do: {:ok, metadata_values(read)}
  end

  # Each attribute once, and no other.
  defp attributes(output) do
    read = output |> String.split("\n", trim: true) |> Enum.reduce_while(%{}, &attribute/2)

    if is_map(read) and
         Enum.sort(Enum.reject(Map.keys(read), &home?/1)) == Enum.sort(@metadata_attributes),
       do: {:ok, read},
       else: :error
  end

  defp home?(name), do: String.starts_with?(name, "home/")

  # The value is the last word: a user's name, from a directory, can hold a space.
  defp attribute(line, read) do
    with [_line, name, value] <- Regex.run(~r/\A(.+) ([A-Za-z0-9+\/=]*|-)\z/, line),
         false <- Map.has_key?(read, name),
         {:ok, value} <- attribute_value(value) do
      {:cont, Map.put(read, name, value)}
    else
      _other -> {:halt, :error}
    end
  end

  defp attribute_value("-"), do: {:ok, nil}
  defp attribute_value(value), do: Base.decode64(value)

  # A user's file in the form of the metadata, `user:key` on each line, so that one check reads both.
  defp metadata_values(read) do
    metadata =
      for attribute <- read_from(read["instance/attributes/block-project-ssh-keys"]),
          value = read[attribute],
          value != nil,
          do: {place(attribute), value}

    homes =
      for {"home/" <> user, value} <- Enum.sort(read),
          value != nil,
          do: {:home, Enum.map_join(String.split(value, "\n"), "\n", &(user <> ":" <> &1))}

    metadata ++ homes
  end

  # The guest agent reads the project's keys unless the instance blocks them. It reads the value
  # with `strconv.ParseBool`, which neither trims it nor reads any other case: a value that this
  # reads as not blocked, and the agent as blocked, only makes ehosctl refuse more.
  defp read_from(blocked) when blocked in ~w(1 t T TRUE true True),
    do: ["instance/attributes/ssh-keys", "instance/attributes/sshKeys"]

  defp read_from(_not_blocked),
    do: [
      "instance/attributes/ssh-keys",
      "instance/attributes/sshKeys",
      "project/attributes/ssh-keys",
      "project/attributes/sshKeys"
    ]

  defp place("instance/" <> _attribute), do: :instance
  defp place("project/" <> _attribute), do: :project

  # The file without the lines, and with a comment for each removed key while it can come back,
  # where a comment is not there already; no write when nothing changes, as in a run again that
  # finds the key still in the metadata.
  defp removed_lines(state, lines, marked, pending, context) do
    marks = if pending, do: marks(lines, marked), else: []
    gone = if pending, do: lines, else: lines ++ marked

    case gone ++ marks do
      [] -> {:ok, []}
      _change -> written(state, (state.keys -- gone) ++ marks, context)
    end
  end

  defp marks(lines, marked) do
    for %{kind: :named, key: key, name: name} <- lines,
        not Enum.any?(marked, &(&1.key == key)),
        uniq: true,
        do: AuthorizedKeys.removed_line(key, name)
  end

  defp written(state, lines, context) do
    with {:ok, write} <-
           lines |> named_shared(context.provisioning) |> keys_written(state, context),
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
  # One step for each binding, so that a failure after one says it is gone.
  defp delete(bindings), do: Enum.map(bindings, &{:delete, [&1]})

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

  # `admin list` would tell to remove the person again, and `remove` would take the new one too.
  defp not_unfinished(lines, name) do
    if Enum.any?(lines, &(&1.kind == :removed and &1.name == name)),
      do:
        {:error,
         "The removal of #{name} is not finished: GCP's guest agent can put their earlier key " <>
           "back. Finish it with `admin remove #{name}`, or give the person another name."},
      else: :ok
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
      warnings:
        counted ++ Enum.flat_map(names, &half_warnings(state, &1)) ++ unfinished(state.keys)
    }
  end

  # A removal that left a comment with the key, as `remove/2` does while GCP's guest agent can put
  # the key back.
  defp unfinished(lines) do
    for %{kind: :removed, name: name} <- lines, uniq: true do
      {"The removal of #{name} is not finished.",
       "GCP's guest agent can put their key on the server. Run `admin remove #{name}`: it says " <>
         "the step to take, then finishes when you run it again."}
    end
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

  @doc """
  The names of the installation administrators in `state`: those with a line that holds an id. A
  name in a binding alone reaches no server over SSH, and does not count as one, so a binding made
  by hand neither lets the last administrator go nor hides that one remains.
  """
  @spec persons(state()) :: [String.t()]
  def persons(state) do
    Enum.uniq(for %{kind: :named, name: name, id: id} <- state.keys, id != nil, do: name)
  end

  defp bound_names(state), do: Enum.uniq(for {name, _id} <- all_users(state.bindings), do: name)

  # The users of `name` that a ClusterRoleBinding makes `cluster-admin`, the grant `add` makes: a
  # RoleBinding of the same user to another role is not it, and does not stop `add` making it.
  defp granted(bindings, name) do
    bindings
    |> Enum.filter(fn binding ->
      binding["kind"] == "ClusterRoleBinding" and
        match?(%{"kind" => "ClusterRole", "name" => "cluster-admin"}, binding["roleRef"])
    end)
    |> users(name)
  end

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

  # A copy of k3s's admin kubeconfig, which `tunnel` wrote before eh-os D-199 and writes while the
  # server keeps the shared key, is in the group system:masters, which no binding grants: removing
  # a person or the shared key does not end it, and only a rotation of the client CA does.
  defp other_ways_in(@shared),
    do:
      {"The key that every administrator shared can still give access.",
       "Delete its private key on each workstation that has it. A kubeconfig that `tunnel` " <>
         "wrote with that key holds the admin certificate of k3s, which works for up to a " <>
         "year: only a rotation of the client CA of the cluster ends it. Delete each such " <>
         "kubeconfig, and run `tunnel` again with a key of your own."}

  defp other_ways_in(name),
    do:
      {"#{name} can still have other ways in.",
       "This does not end their access to the cloud account, their copy of the state and its " <>
         "passphrase, an SSH session that is open, or access that they made while they were " <>
         "an administrator. `admin list` shows each binding to cluster-admin. It also does not " <>
         "end a kubeconfig with the admin certificate of k3s that an earlier `tunnel` wrote " <>
         "for them. That certificate works for up to a year, `admin list` cannot show it, and " <>
         "only a rotation of the client CA of the cluster ends it."}

  # Runs `steps` in order and stops at the first that fails.
  # A failure after a step that changed the server says what is already done, so that nobody reads
  # "changed nothing" while a binding is gone.
  # `:changed` when the write of authorized_keys found the file changed since it was read, or found
  # it changed right after the write without the administrators' lines as written. That write is
  # the first step of every plan, so no binding changed, and `change/4` reads it and plans again.
  defp execute(server, address, steps) do
    steps
    |> Enum.reduce_while([], fn step, done ->
      case run_step(server, address, step) do
        :ok -> {:cont, [step | done]}
        :changed -> {:halt, :changed}
        {:error, message} -> {:halt, {:error, done_before(message, Enum.reverse(done))}}
      end
    end)
    |> executed()
  end

  defp executed({:error, message}), do: {:error, message}
  defp executed(:changed), do: :changed
  defp executed(_done), do: :ok

  # Reads the server, plans with `planner`, and runs the plan; reads and plans again when the write
  # of authorized_keys found the file changed, as GCP's guest agent rewrites the whole file on each
  # run (eh-os#1836). A new plan is made only while each administrator's line is as the first read
  # found it, so that ehosctl never writes over a change of the administrators that it did not
  # read; a change of other lines, which the new plan keeps, does not stop it.
  # `state`, when given, is what the caller read already, for the first attempt.
  defp change(server, address, planner, state \\ nil),
    do: attempt(%{server: server, address: address, planner: planner, first: nil}, 1, state)

  defp attempt(run, attempt, nil) do
    with {:ok, state} <- read(run.server, run.address), do: attempt(run, attempt, state)
  end

  defp attempt(run, attempt, state) do
    with :ok <- same_administrators(run, state),
         planned = run.planner.(state),
         {:ok, plan} <- plan_of(planned) do
      run.server
      |> execute(run.address, plan.steps)
      |> retried(planned, %{run | first: run.first || state}, attempt)
    end
  end

  # `plan_add/5` gives the id with its plan, `plan_remove/3` the plan alone.
  defp plan_of({:ok, plan}), do: {:ok, plan}
  defp plan_of({:ok, plan, _id}), do: {:ok, plan}
  defp plan_of(error), do: error

  defp retried(:ok, planned, _run, _attempt), do: planned
  defp retried({:error, message}, _planned, _run, _attempt), do: {:error, message}

  defp retried(:changed, _planned, run, attempt) when attempt < @attempts do
    run.server.clock.sleep(@pause)
    attempt(run, attempt + 1, nil)
  end

  defp retried(:changed, _planned, run, _attempt),
    do:
      {:error,
       "ehosctl did not change authorized_keys, because it changed on ehos-#{run.server.name} " <>
         "each of the #{@attempts} times after ehosctl read it. Run the command again."}

  defp same_administrators(%{first: nil}, _state), do: :ok

  defp same_administrators(%{first: first, server: server}, state) do
    if administrator_lines(first) == administrator_lines(state),
      do: :ok,
      else:
        {:error,
         "ehosctl did not change authorized_keys, because the line of an installation " <>
           "administrator, or of shared, changed on ehos-#{server.name} after ehosctl read it. " <>
           "Run `admin list` to see the change, then run the command again."}
  end

  # The lines that name an administrator, `shared` among them, in any order: GCP's guest agent
  # writes the lines of the file in another order each time.
  defp administrator_lines(state),
    do:
      state.keys
      |> Enum.filter(&(&1.kind in [:named, :removed]))
      |> Enum.map(& &1.text)
      |> Enum.sort()

  defp done_before(message, []), do: message

  defp done_before(message, done) do
    said = Enum.map_join(done, ", ", &done_said/1)

    Failure.added(
      message,
      "\nBefore this, ehosctl changed the server: #{said}. Run the command again to finish."
    )
  end

  defp done_said({:write_keys, _hash, _contents}), do: "wrote authorized_keys"
  defp done_said({:create, binding}), do: "created #{shown_binding(binding)}"

  defp done_said({:replace, bindings}),
    do: "took the person out of " <> Enum.map_join(bindings, ", ", &shown_binding/1)

  defp done_said({:delete, bindings}),
    do: "deleted " <> Enum.map_join(bindings, ", ", &shown_binding/1)

  defp run_step(server, address, {:write_keys, hash, contents}) do
    server.progress.({:step, "Writing authorized_keys on ehos-#{server.name}"})

    token = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    input = hash <> "\n" <> token <> "\n" <> contents

    case Server.on_server(server, address, @write_script, input: input) do
      {_output, 0} ->
        server
        |> confirm(address, token, Base.encode16(:crypto.hash(:sha256, contents), case: :lower))
        |> confirmed(server, address, contents)

      {_output, 75} ->
        {:error,
         "ehosctl did not change authorized_keys, because another ehosctl was changing it on " <>
           "ehos-#{server.name} for 2 minutes. Run the command again."}

      {_output, 76} ->
        :changed

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
  defp confirm(server, address, token, written) do
    input = token <> "\n" <> written <> "\n"

    case Server.on_server(server, address, @confirm_script, fresh: true, input: input) do
      {_output, 0} ->
        :ok

      {_output, 77} ->
        :moved

      {output, 255} ->
        {:error,
         Failure.printed(
           "The server did not take your key after the change of authorized_keys. It puts the " <>
             "previous file back within 60 seconds, so a line that this command removed, such as " <>
             "the line of an installation administrator, is back too. Run the command again " <>
             "after that.",
           "ssh",
           output
         )}

      _put_back ->
        {:error,
         "The server put the previous authorized_keys back, because ehosctl did not confirm " <>
           "the new one within 60 seconds, so a line that this command removed, such as the " <>
           "line of an installation administrator, is back too. Run the command again."}
    end
  end

  # The file changed right after the write: GCP's guest agent rewrites it on each run, in another
  # order, and keeps the lines it did not write, or writes back what it read before the write
  # (ehos-tools#1156). The write holds when every line that names an administrator is as written;
  # else `:changed`, and `change/4` reads and plans again, from a file that holds none of this
  # write's own change when the agent wrote back the file it read before.
  defp confirmed(:moved, server, address, contents) do
    case read(server, address) do
      {:ok, state} ->
        kept(state, contents)

      {:error, message} ->
        {:error,
         Failure.within(
           message,
           "authorized_keys changed on ehos-#{server.name} right after ehosctl wrote it, and " <>
             "ehosctl could not read it again: ",
           " ehosctl stopped before it changed anything else. Run the command again."
         )}
    end
  end

  defp confirmed(result, _server, _address, _contents), do: result

  defp kept(state, contents) do
    written = %{keys: AuthorizedKeys.parse(contents)}
    if administrator_lines(state) == administrator_lines(written), do: :ok, else: :changed
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
    with {:ok, session} <- session(server, "to keep it on the server") do
      {:ok,
       %{
         session: session,
         provisioning: provisioning(server),
         provider: server.provider,
         first?: false,
         metadata: []
       }}
    end
  end

  defp session(server, why \\ "to find the installation administrator whose line holds it") do
    case public_key(server) do
      nil ->
        key = Shell.word(server.ssh_key)

        {:error,
         "ehosctl needs #{server.ssh_key}.pub, the public key of the key that you log in with, " <>
           "#{why}, and cannot get it from the private key, as when the key has a passphrase. " <>
           "Write it with `pub=$(ssh-keygen -y -f #{key}) && printf '%s\\n' \"$pub\" >| " <>
           "#{Shell.word(server.ssh_key <> ".pub")}`, then run the command again."}

      session ->
        {:ok, session}
    end
  end

  @doc """
  The fingerprint of the public key of the key this workstation logs in with, as
  `EhosPlatform.Server.AuthorizedKeys.fingerprint/1` gives it, or `nil` when ehosctl cannot get
  that key.
  """
  @spec fingerprint(Server.t()) :: String.t() | nil
  def fingerprint(server) do
    case public_key(server) do
      nil -> nil
      key -> AuthorizedKeys.fingerprint(key)
    end
  end

  # The `.pub` beside the private key, else the public key `ssh-keygen` reads from the private key:
  # ehosctl 0.49.0's handover gave a person the private key alone. The empty passphrase makes a
  # key that has one fail rather than ask.
  defp public_key(server) do
    AuthorizedKeys.key_of(public_file(server.ssh_key)) || derived_key(server)
  end

  defp derived_key(server) do
    # A path that names a FIFO, as a copied folder can, would hold `ssh-keygen` for ever.
    case server.runner.run_bounded("ssh-keygen", ["-y", "-P", "", "-f", server.ssh_key], 10_000) do
      {output, 0} -> AuthorizedKeys.key_of(output)
      _failed -> nil
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # Only a regular file: a FIFO, as a copied folder can name, would hold the read for ever.
  defp public_file(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.stat(path <> ".pub"),
         {:ok, contents} <- File.read(path <> ".pub") do
      contents
    else
      _none -> nil
    end
  end

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

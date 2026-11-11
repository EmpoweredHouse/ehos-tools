defmodule EhosPlatform.Dns do
  @moduledoc """
  Questions to DNS, as a way out (T-20): `EhosPlatform.DomainRecords` asks the company's own name
  servers for the records an installation with public certificates needs (eh-os D-158), and a test
  says what they answer. A caller names an implementation in `opts[:dns]`, and
  `EhosPlatform.DnsImpl`, which asks with Erlang's `:inet_res`, is the default.
  """

  @typedoc """
  One record of an answer: its owner, lowercase and without the trailing dot, its type, and its
  data. The data is an IP address as text for `:a` and `:aaaa`, a name for `:ns`, `:cname` and
  `:soa` (the zone's primary name server), and `{flags, tag, value}` for `:caa`.
  """
  @type resource_record :: %{
          name: String.t(),
          type: atom(),
          data: String.t() | {non_neg_integer(), String.t(), String.t()}
        }

  @typedoc """
  A server's answer: its response code (`:noerror`, `:nxdomain`, or another), the records of its
  answer section, and those of its authority section, where a referral and a zone's `SOA` are.
  """
  @type reply :: %{rcode: atom(), answers: [resource_record()], authority: [resource_record()]}

  @doc """
  Asks `server` for the records of `type` at `name`: at an IPv4 address, with no recursion, as an
  authoritative server is asked; or `:recursive`, through this machine's own resolver. `{:error,
  reason}` when no answer came, as a sentence.
  """
  @callback query(name :: String.t(), type :: atom(), server :: :inet.ip4_address() | :recursive) ::
              {:ok, reply()} | {:error, String.t()}

  @doc """
  Asks the server at an IPv4 address for the records of `type` at `name`, as `query/3` does, but
  with a timeout of 1 second and one more try, about 2 seconds at most: for a question where no
  answer is the common result, and an answer, if one comes, comes at once.
  """
  @callback probe(name :: String.t(), type :: atom(), server :: :inet.ip4_address()) ::
              {:ok, reply()} | {:error, String.t()}
end

defmodule EhosPlatform.DnsImpl do
  @moduledoc "The `EhosPlatform.Dns` that asks with Erlang's `:inet_res`, over UDP, then TCP."

  @behaviour EhosPlatform.Dns

  @timeout 5_000
  @probe_timeout 1_000

  @impl true
  def query(name, type, :recursive), do: resolve(name, type, timeout: @timeout)

  def query(name, type, address),
    do:
      resolve(name, type,
        nameservers: [{address, 53}],
        recurse: false,
        retry: 2,
        timeout: @timeout
      )

  @impl true
  def probe(name, type, address),
    do:
      resolve(name, type,
        nameservers: [{address, 53}],
        recurse: false,
        retry: 2,
        timeout: @probe_timeout
      )

  defp resolve(name, type, options) do
    case :inet_res.resolve(String.to_charlist(name), :in, type, options) do
      {:ok, message} ->
        {:ok, reply(message)}

      # An answer without records, `NXDOMAIN`, `REFUSED` and `SERVFAIL` among them, is an answer:
      # its message is kept, with its response code, for the caller to read.
      {:error, {:nxdomain, message}} when is_tuple(message) ->
        {:ok, reply(message)}

      {:error, {code, message}} when is_tuple(message) ->
        {:ok, reply(message) |> Map.put(:rcode, code)}

      {:error, :nxdomain} ->
        {:ok, %{rcode: :nxdomain, answers: [], authority: []}}

      {:error, reason} ->
        {:error, "no answer (#{inspect(reason)})"}
    end
  end

  defp reply(message) do
    header = :inet_dns.msg(message, :header)

    %{
      rcode: rcode(:inet_dns.header(header, :rcode)),
      answers: records(:inet_dns.msg(message, :anlist)),
      authority: records(:inet_dns.msg(message, :nslist))
    }
  end

  defp rcode(0), do: :noerror
  defp rcode(3), do: :nxdomain
  defp rcode(2), do: :servfail
  defp rcode(5), do: :refused
  defp rcode(code), do: code

  defp records(list) do
    for rr <- list,
        type = :inet_dns.rr(rr, :type),
        data = data(type, :inet_dns.rr(rr, :data)),
        data != nil,
        do: %{name: name(:inet_dns.rr(rr, :domain)), type: type, data: data}
  end

  defp data(type, address) when type in [:a, :aaaa], do: address |> :inet.ntoa() |> to_string()
  defp data(type, target) when type in [:ns, :cname], do: name(target)
  defp data(:soa, soa) when is_tuple(soa), do: soa |> elem(0) |> name()

  defp data(:caa, {flags, tag, value}),
    do: {flags, to_string(tag), to_string(value)}

  defp data(_type, _data), do: nil

  defp name(name), do: name |> to_string() |> String.trim_trailing(".") |> String.downcase()
end

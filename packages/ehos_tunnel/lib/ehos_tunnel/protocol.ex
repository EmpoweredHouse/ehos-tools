defmodule EhosTunnel.Protocol do
  @moduledoc """
  The words and numbers of the data tunnel, `ehos-tunnel.v1`, that a client and the data gateway
  agree on (eh-os D-179): the path and the subprotocol, the refusals before the upgrade, the close
  codes after it, the end reasons, and the bounds on frames and silence.

  A tunnel is one HTTP/1.1 request, `GET /v1/sessions/<id>/tunnel` with
  `Sec-WebSocket-Protocol: ehos-tunnel.v1`, upgraded to a WebSocket whose binary frames carry one
  TCP connection's bytes.

  Words read from the wire become atoms only from the lists here; a word this version does not
  know stays a string, so a later gateway's word still reaches whoever reads it.
  """

  @typedoc "Why the gateway refused a tunnel before the upgrade, by its `reason` word."
  @type refusal_reason ::
          :malformed | :refused | :ended | :too_many | :instance_unreachable | :unavailable

  @typedoc """
  Why a session ended, by its `endReason` word: the API's, and `:revoked` when its person no
  longer holds the right or is disabled. A word this version does not know stays a string.
  """
  @type end_reason ::
          :ended
          | :expired
          | :not_applied
          | :refused
          | :deployment
          | :gone
          | :revoked
          | String.t()

  @typedoc """
  A refusal as a client reads it: the HTTP status, the `reason` word (a string when this version
  does not know it, and the status's own when the body has none, or `nil` for a status that is no
  refusal's), the gateway's sentence, and, for `:ended`, the session's end reason.
  """
  @type refusal :: %{
          status: pos_integer(),
          reason: refusal_reason() | String.t() | nil,
          message: String.t() | nil,
          end_reason: end_reason() | nil
        }

  @typedoc "Why the gateway closed an open tunnel, by its close code."
  @type close_reason ::
          :normal | :going_away | :text_frame | :too_big | :failed | :session_ended

  @typedoc """
  A close as a client reads it: the close code, its meaning (the code itself when this version
  does not know it), and, for `:session_ended`, the session's end reason from the reason text.
  """
  @type close :: %{
          code: non_neg_integer() | nil,
          reason: close_reason() | non_neg_integer() | nil,
          end_reason: end_reason() | nil
        }

  @refusals [
    malformed: 400,
    refused: 403,
    ended: 409,
    too_many: 429,
    instance_unreachable: 502,
    unavailable: 503
  ]

  @refusal_reasons Keyword.keys(@refusals)

  @closes [
    normal: 1000,
    going_away: 1001,
    text_frame: 1003,
    too_big: 1009,
    failed: 1011,
    session_ended: 4001
  ]

  @end_reasons [:ended, :expired, :not_applied, :refused, :deployment, :gone, :revoked]

  @doc "The WebSocket subprotocol a client asks for and the gateway answers with."
  @spec subprotocol() :: String.t()
  def subprotocol, do: "ehos-tunnel.v1"

  @doc """
  The path of a session's tunnel.

      iex> EhosTunnel.Protocol.path("9f0c")
      "/v1/sessions/9f0c/tunnel"
  """
  @spec path(String.t()) :: String.t()
  def path(session_id) when is_binary(session_id), do: "/v1/sessions/#{session_id}/tunnel"

  @doc """
  A session's tunnel URL on the gateway at `base`, its scheme and host (`wss://data.<host>`), as a
  session's `tunnel.url` names it.

      iex> EhosTunnel.Protocol.url("wss://data.ehos.example.com", "9f0c")
      "wss://data.ehos.example.com/v1/sessions/9f0c/tunnel"
  """
  @spec url(String.t(), String.t()) :: String.t()
  def url(base, session_id), do: String.trim_trailing(base, "/") <> path(session_id)

  @doc "The largest frame either side sends or takes: 1 MiB, in bytes."
  @spec max_frame_size() :: pos_integer()
  def max_frame_size, do: 1_048_576

  @doc "How often the gateway pings an open tunnel, in milliseconds."
  @spec ping_interval() :: pos_integer()
  def ping_interval, do: 30_000

  @doc """
  How long a tunnel may send nothing, a pong included, before the gateway closes it, in
  milliseconds.
  """
  @spec silence_timeout() :: pos_integer()
  def silence_timeout, do: 90_000

  @doc "The refusals before the upgrade, each `reason` word with its HTTP status."
  @spec refusals() :: [{refusal_reason(), pos_integer()}]
  def refusals, do: @refusals

  @doc "The HTTP status of a refusal."
  @spec refusal_status(refusal_reason()) :: pos_integer()
  def refusal_status(reason), do: Keyword.fetch!(@refusals, reason)

  @doc """
  The JSON body of a refusal, `{"error": {"reason", "message", "endReason"?}}`, with `endReason`
  only when `end_reason` is given.

      iex> EhosTunnel.Protocol.refusal_body(:ended, "The session ended.", :expired)
      ~s({"error":{"endReason":"expired","message":"The session ended.","reason":"ended"}})
  """
  @spec refusal_body(refusal_reason(), String.t(), end_reason() | nil) :: String.t()
  def refusal_body(reason, message, end_reason \\ nil)
      when reason in @refusal_reasons and is_binary(message) do
    %{"reason" => Atom.to_string(reason), "message" => message}
    |> maybe_put("endReason", end_reason && to_string(end_reason))
    |> then(&JSON.encode!(%{"error" => &1}))
  end

  @doc """
  Reads a refusal from the gateway's status and body. A body that is not the refusal's JSON still
  gives the status, with the `reason` its status means, and no message.

      iex> EhosTunnel.Protocol.refusal(409, ~s({"error": {"reason": "ended", "message": "It ended.", "endReason": "revoked"}}))
      %{status: 409, reason: :ended, message: "It ended.", end_reason: :revoked}
  """
  @spec refusal(pos_integer(), binary()) :: refusal()
  def refusal(status, body) when is_integer(status) and is_binary(body) do
    case decode_error(body) do
      %{} = error ->
        %{
          status: status,
          reason: refusal_reason(error["reason"], status),
          message: string(error["message"]),
          end_reason: end_reason(error["endReason"])
        }

      nil ->
        %{status: status, reason: refusal_reason(nil, status), message: nil, end_reason: nil}
    end
  end

  @doc "The close codes after the upgrade, each meaning with its code."
  @spec closes() :: [{close_reason(), pos_integer()}]
  def closes, do: @closes

  @doc "The close code of a close reason."
  @spec close_code(close_reason()) :: pos_integer()
  def close_code(reason), do: Keyword.fetch!(@closes, reason)

  @doc """
  Reads a close from its code and reason text. The text is read as the session's end reason for
  4001 alone.

      iex> EhosTunnel.Protocol.close(4001, "revoked")
      %{code: 4001, reason: :session_ended, end_reason: :revoked}
  """
  @spec close(non_neg_integer() | nil, binary() | nil) :: close()
  def close(4001, text), do: %{code: 4001, reason: :session_ended, end_reason: end_reason(text)}

  def close(code, _text) do
    reason =
      Enum.find_value(@closes, code, fn {reason, known} -> if known == code, do: reason end)

    %{code: code, reason: if(code, do: reason), end_reason: nil}
  end

  @doc "The end reasons this version knows."
  @spec end_reasons() :: [end_reason()]
  def end_reasons, do: @end_reasons

  @doc """
  Reads an end reason word: an atom from `end_reasons/0`, the word itself when this version does
  not know it, and `nil` for nothing.
  """
  @spec end_reason(term()) :: end_reason() | nil
  def end_reason(word) when is_binary(word) and word != "" do
    Enum.find(@end_reasons, word, &(Atom.to_string(&1) == word))
  end

  def end_reason(_word), do: nil

  defp refusal_reason(word, _status) when is_binary(word) and word != "" do
    Enum.find_value(@refusals, word, fn {reason, _status} ->
      if Atom.to_string(reason) == word, do: reason
    end)
  end

  defp refusal_reason(_word, status) do
    Enum.find_value(@refusals, fn {reason, known} -> if known == status, do: reason end)
  end

  defp decode_error(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => %{} = error}} -> error
      _not_a_refusal -> nil
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

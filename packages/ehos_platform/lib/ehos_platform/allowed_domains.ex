defmodule EhosPlatform.AllowedDomains do
  @moduledoc """
  The company's domains under which a person may map an application's entry (eh-os D-155), the
  chart's `environments.domains.allowed`, checked before the installer gives them to the chart.

  The chart checks the form of each domain and refuses the console's host, but it has no Public
  Suffix List: D-155 leaves that to the installer and the governance plane. A domain on the list,
  such as `co.uk` or `github.io`, belongs to no one company, and a mapping under it could claim a
  name of another company. The list is `public_sufx`'s, with its private section, its wildcards
  and its exceptions; its releases follow the list, and the dependency updates keep it current.
  """

  # The chart's own form (eh-os `_helpers.tpl`, `ehos.allowedDomains`): lowercase A-labels, at
  # least two, the last starting with a letter, so never an address.
  @form ~r/\A([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z]([-a-z0-9]{0,61}[a-z0-9])?\z/
  @longest 200

  @doc """
  `:ok` when every domain of `domains` may be allowed on an installation whose console is at
  `host`, else `{:error, sentence}` for the first that may not: one that is not a lowercase
  A-label of at least two labels and at most #{@longest} characters, the console's host or a name
  under it, or a public suffix.

      iex> EhosPlatform.AllowedDomains.check(["client.example"], "ehos.client.example")
      :ok

      iex> {:error, message} = EhosPlatform.AllowedDomains.check(["co.uk"], "ehos.client.example")
      iex> message =~ "co.uk is on the Public Suffix List"
      true
  """
  @spec check([String.t()], String.t()) :: :ok | {:error, String.t()}
  def check(domains, host) do
    Enum.find_value(domains, :ok, &refused(&1, host))
  end

  defp refused(domain, host) do
    cond do
      not is_binary(domain) or byte_size(domain) > @longest or not (domain =~ @form) ->
        {:error,
         "#{inspect(domain)} is not a domain that can be allowed. Give a domain name in " <>
           "lowercase, of at least two labels and at most #{@longest} characters, such as " <>
           "client.example. Give an internationalized name as its A-label (xn--…). Nothing " <>
           "was changed"}

      domain == host or String.ends_with?(domain, "." <> host) ->
        {:error,
         "#{domain} is the console's host or a name under it, #{host}, which no mapping may " <>
           "claim. Give a domain of your company outside it. Nothing was changed"}

      PublicSufx.public_suffix?(domain) ->
        {:error,
         "#{domain} is on the Public Suffix List: names under it belong to many owners, not to " <>
           "your company. Give a domain that your company registered, such as " <>
           "client.#{domain}. Nothing was changed"}

      true ->
        nil
    end
  end
end

defmodule EhosRelease.Fragment do
  @moduledoc """
  One changelog fragment, as `changie new` writes it (eh-os D-205, "The changelog"): its project,
  its kind, its text, whether it breaks what the version before offered, and the issue its work
  belongs to, which must be an issue of eh-os, ehos-tools or ehos_contract (T-34).
  """

  alias EhosRelease.{ChangieConfig, Source}

  @enforce_keys [:file, :project, :kind, :body, :breaking, :issue]
  defstruct @enforce_keys

  @typedoc "A fragment."
  @type t :: %__MODULE__{
          file: String.t(),
          project: String.t(),
          kind: String.t(),
          body: String.t(),
          breaking: boolean(),
          issue: String.t()
        }

  @kinds ~w(Added Changed Deprecated Removed Fixed Security)
  @issue ~r/\AEmpoweredHouse\/(?:eh-os|ehos-tools|ehos_contract)#[1-9][0-9]*\z/

  @doc """
  The fragments of `projects` not released yet, and a refusal for each file in the directory of
  fragments that is not one, whatever its project. Fragments of other projects are left out.
  """
  @spec read(Source.t(), ChangieConfig.t(), [String.t()]) :: {[t()], [String.t()]}
  def read(%Source{} = source, %ChangieConfig{} = config, projects) do
    case Source.list(source, ChangieConfig.unreleased(config), [".yaml", ".yml"]) do
      {:ok, files} ->
        results = Enum.map(files, &read_file(source, &1))

        {for({:ok, fragment} <- results, fragment.project in projects, do: fragment),
         for({:error, reason} <- results, do: reason)}

      {:error, reason} ->
        {[], [reason]}
    end
  end

  @doc """
  The issue a fragment names, as its repository and number.

      iex> EhosRelease.Fragment.issue("EmpoweredHouse/eh-os#1914")
      {"EmpoweredHouse/eh-os", 1914}
  """
  @spec issue(String.t()) :: {String.t(), pos_integer()}
  def issue(issue) do
    [repository, number] = String.split(issue, "#")
    {repository, String.to_integer(number)}
  end

  defp read_file(source, file) do
    with {:ok, yaml} <- Source.read(source, file),
         {:ok, %{} = fields} <- YamlElixir.read_from_string(yaml) do
      fragment(file, fields)
    else
      _other -> {:error, "#{file} is not a fragment changie can read"}
    end
  end

  defp fragment(file, %{"project" => project, "kind" => kind, "body" => body} = fields)
       when is_binary(project) and is_binary(kind) and is_binary(body) do
    custom = Map.get(fields, "custom") || %{}

    cond do
      kind not in @kinds ->
        {:error, "#{file}: #{inspect(kind)} is not one of #{Enum.join(@kinds, ", ")}"}

      custom["Breaking"] not in ["Yes", "No"] ->
        {:error, "#{file}: Breaking is not Yes or No"}

      not (is_binary(custom["Issue"]) and custom["Issue"] =~ @issue) ->
        {:error,
         "#{file}: Issue is not an issue of eh-os, ehos-tools or ehos_contract, owner/repo#n"}

      true ->
        {:ok,
         %__MODULE__{
           file: file,
           project: project,
           kind: kind,
           body: body,
           breaking: custom["Breaking"] == "Yes",
           issue: custom["Issue"]
         }}
    end
  end

  defp fragment(file, _fields), do: {:error, "#{file} has no project, kind or body"}
end

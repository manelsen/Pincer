defmodule Pincer.Core.UX.ModelKeyboard do
  @moduledoc "Módulo de paginação de botões de modelo"

  alias Pincer.Core.ChannelInteractionPolicy

  @page_size 8

  @doc "Returns the number of models displayed per page."
  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  @spec paginate([String.t()], pos_integer()) :: {[String.t()], pos_integer()}
  def paginate(items, page) when is_list(items) and is_integer(page) and page >= 1 do
    total_pages = max(1, ceil(length(items) / @page_size))
    page = min(page, total_pages)
    offset = (page - 1) * @page_size
    page_items = Enum.slice(items, offset, @page_size)
    {page_items, total_pages}
  end

  @spec build_model_row(atom(), String.t(), String.t(), String.t() | nil) :: map() | nil
  def build_model_row(channel, provider_id, model_label, current_model) do
    # Strip (FREE) tag if present to get the real model ID
    model_id = String.replace(model_label, " (FREE)", "")
    
    case ChannelInteractionPolicy.model_selector_id(channel, provider_id, model_id) do
      {:ok, callback_data} ->
        is_current = model_id == current_model
        label = if is_current, do: "#{model_label} ✓", else: model_label
        
        case channel do
          :telegram -> %{text: label, callback_data: callback_data}
          :discord -> %{type: 2, style: 1, label: label, custom_id: callback_data}
        end
      {:error, _} -> nil
    end
  end

  @spec build_pagination_row(atom(), String.t(), pos_integer(), pos_integer()) :: [map()]
  def build_pagination_row(_channel, _provider_id, _current_page, 1), do: []
  def build_pagination_row(channel, provider_id, current_page, total_pages) do
    prev_payload = "page:#{provider_id}:#{current_page - 1}"
    next_payload = "page:#{provider_id}:#{current_page + 1}"
    counter_label = "#{current_page}/#{total_pages}"

    case channel do
      :telegram ->
        prev_btn = if current_page > 1, do: [%{text: "◀ Prev", callback_data: prev_payload}], else: []
        counter = [%{text: counter_label, callback_data: "noop"}]
        next_btn = if current_page < total_pages, do: [%{text: "Next ▶", callback_data: next_payload}], else: []
        prev_btn ++ counter ++ next_btn

      :discord ->
        prev_btn = if current_page > 1, do: [%{type: 2, style: 2, label: "◀ Prev", custom_id: prev_payload}], else: []
        counter = [%{type: 2, style: 2, label: counter_label, custom_id: "noop", disabled: true}]
        next_btn = if current_page < total_pages, do: [%{type: 2, style: 2, label: "Next ▶", custom_id: next_payload}], else: []
        prev_btn ++ counter ++ next_btn
    end
  end

  @spec build_keyboard(atom(), String.t(), [String.t()], pos_integer(), String.t() | nil) :: any()
  def build_keyboard(channel, provider_id, models, page, current_model) do
    {page_models, total_pages} = paginate(models, page)
    
    model_rows =
      page_models
      |> Enum.map(&build_model_row(channel, provider_id, &1, current_model))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&[&1])

    pagination_row = build_pagination_row(channel, provider_id, page, total_pages)
    
    back_row = case ChannelInteractionPolicy.back_to_providers_id(channel) do
      {:ok, cb} -> 
        case channel do
          :telegram -> [[%{text: "⬅️ Voltar", callback_data: cb}]]
          :discord -> [[%{type: 2, style: 2, label: "⬅️ Voltar", custom_id: cb}]]
        end
      _ -> []
    end

    rows = if pagination_row == [], do: model_rows, else: model_rows ++ [pagination_row]
    rows ++ back_row
  end
end

defmodule Spandex.Trace do
  use GenServer

  defmacro span(name, do: body) do
    if Application.get_env(:spandex, :disabled?) do
      quote do
        _ = unquote(name)
        unquote(body)
      end
    else
      quote do
        name = unquote(name)
        Spandex.Trace.start_span(name)

        try do
          return_value = unquote(body)
          Spandex.Trace.end_span()
          return_value
        rescue
          exception ->
            Spandex.Trace.span_error(exception)
          raise exception
        end
      end
    end
  end

  def start(opts \\ []) do
    if Application.get_env(:spandex, :disabled?) do
      :disabled
    else
      server_state = setup_state(opts)
      GenServer.start(
        __MODULE__,
        server_state,
        name: server_state[:name]
      )
    end
  end

  def init(state) do
    kill_me_in(state[:ttl_seconds], self())
    {:ok, state}
  end

  def publish() do
    safely_with_enabled_and_active_trace(fn trace_pid ->
      GenServer.cast(trace_pid, {:publish, Spandex.Span.now()})
      GenServer.cast(trace_pid, :stop)
    end)
  end

  def start_span(name) do
    safely_with_enabled_and_active_trace(&GenServer.cast(&1, {:start_span, name, Spandex.Span.now()}))
  end

  def end_span() do
    safely_with_enabled_and_active_trace(&GenServer.cast(&1, {:end_span, Spandex.Span.now()}))
  end

  def update_span(update, override? \\ true) do
    safely_with_enabled_and_active_trace(&GenServer.cast(&1, {:update_span, update, override?}))
  end

  def update_span_branch(update, override? \\ true) do
    safely_with_enabled_and_active_trace(&GenServer.cast(&1, {:update_span_branch, update, override?}))
  end

  def update_all_spans(update, override? \\ true) do
    safely_with_enabled_and_active_trace(&GenServer.cast(&1, {:update_all_spans, update, override?}))
  end

  def span_error(exception) do
    message = Exception.message(exception)
    stacktrace = Exception.format_stacktrace(System.stacktrace)
    type = exception.__struct__

    update_span_branch(%{error: 1, error_message: message, stacktrace: stacktrace, error_type: type})

    end_span()
  end

  defp safely_with_enabled_and_active_trace(func) do
    trace_pid =
      :spandex_trace
      |> :ets.lookup(self())
      |> Enum.at(0)
      |> Kernel.||({nil, nil})
      |> elem(1)
    if Application.get_env(:spandex, :disabled?) do
      :ok
    else
      if trace_pid do
        func.(trace_pid)
      end
      :ok
    end
  rescue
    exception -> {:error, exception}
  end

  defp do_publish(%{spans: spans, host: host, port: port}) do
    all_spans =
      spans
      |> Map.values
      |> Enum.map(&Spandex.Span.to_json/1)

    json = Poison.encode!([all_spans])
    case HTTPoison.put "#{host}:#{port}/v0.3/traces", json, [{"Content-Type", "application/json"}] do
      {:ok, body} -> {:ok, body}
      {:error, body} -> {:error, body}
    end
  end

  defp kill_me_in(seconds, pid) do
    spawn_link fn ->
      :timer.sleep(seconds * 1000)
      GenServer.cast(pid, :stop)
      Process.exit(self(), :kill)
    end
  end

  defp setup_state(opts) do
    trace_id = trace_id()
    opts
    |> Enum.into(%{})
    |> Map.put_new(:resource, Application.get_env(:spandex, :resource, "unknown"))
    |> Map.put_new(:service, Application.get_env(:spandex, :service, "unknown"))
    |> Map.put_new(:ttl_seconds, Application.get_env(:spandex, :ttl_seconds, 30))
    |> Map.put_new(:host, Application.get_env(:spandex, :host, "localhost"))
    |> Map.put_new(:port, port(Application.get_env(:spandex, :port, 8126)))
    |> Map.put_new(:env, Application.get_env(:spandex, :env, "unknown"))
    |> Map.put_new(:type, Application.get_env(:spandex, :type, "web"))
    |> Map.put_new(:top_span_name, Application.get_env(:spandex, :top_span_name, "top"))
    |> Map.put_new(:process_name, :"Spandex.Trace:#{trace_id}")
    |> Map.put_new(:trace_id, trace_id)
    |> Map.put_new(:spans, %{})
    |> Map.put(:span_stack, [])
    |> top_span
  end

  defp trace_id(), do: :rand.uniform(9223372036854775807)

  defp port(string) when is_bitstring(string), do: String.to_integer(string)
  defp port(integer) when is_integer(integer), do: integer

  defp top_span(state = %{span_stack: stack, spans: spans}) do
    top_span = %Spandex.Span{
      id: trace_id(),
      trace_id: state[:trace_id],
      resource: state[:resource],
      service: state[:service],
      env: state[:env],
      type: state[:type],
      name: state[:top_span_name]
    }
    |> Spandex.Span.begin(nil)

    %{state | spans: Map.put(spans, top_span.id, top_span), span_stack: [top_span.id | stack]}
  end

  defp new_span(name, state, time) do
    parent_id = Enum.at(state[:span_stack], 0)

    if parent_id do
      state
      |> Map.get(:spans)
      |> Map.get(parent_id)
      |> Spandex.Span.child_of(name, trace_id())
      |> Spandex.Span.begin(time)
    else
      %Spandex.Span{
        id: trace_id(),
        trace_id: state[:trace_id],
        resource: state[:resource],
        service: state[:service],
        env: state[:env],
        type: state[:type],
        name: name
      }
      |> Spandex.Span.begin(time)
    end
  end

  defp put_span(state = %{spans: spans, span_stack: stack}, span = %{id: id}) do
    %{state | spans: Map.put(spans, id, span), span_stack: [id | stack]}
  end

  defp complete_span(state, time) do
    state
    |> edit_span(%{completion_time: time || Spandex.Span.now()}, false)
    |> pop_span
  end

  defp edit_span(state = %{spans: spans, span_stack: stack}, update, override?) do
    span_id = Enum.at(stack, 0)
    if spans[span_id] do
      updated_spans = Map.update!(spans, span_id, &Spandex.Span.update(&1, update, override?))

      Map.put(state, :spans, updated_spans)
    else
      state
    end
  end

  defp edit_span_branch(state = %{spans: spans, span_stack: stack}, update, override?) do
    new_spans = Enum.reduce(stack, spans, fn span_id, span_map ->
      Map.update!(span_map, span_id, &Spandex.Span.update(&1, update, override?))
    end)

    %{state | spans: new_spans}
  end

  defp edit_all_spans(state = %{spans: spans}, update, override?) do
    new_spans = Enum.into(spans, %{}, fn {span_id, span} ->
      {span_id, Spandex.Span.update(span, update, override?)}
    end)
    new_state = merge_update(state, update, override?)
    %{new_state | spans: new_spans}
  end

  defp merge_update(state, update, true), do: Map.merge(state, update)
  defp merge_update(state, update, false), do: Map.merge(update, state)

  defp pop_span(state = %{span_stack: []}), do: state
  defp pop_span(state = %{span_stack: [_|tail]}), do: %{state | span_stack: tail}

  # Callbacks
  def handle_cast({:start_span, name, time}, state) do
    new_state =
      state
      |> put_span(new_span(name, state, time))

    {:noreply, new_state}
  end

  def handle_cast({:end_span, time}, state) do
    {:noreply, complete_span(state, time)}
  end

  def handle_cast({:update_span, update, override?}, state) do
    {:noreply, edit_span(state, update, override?)}
  end

  def handle_cast({:update_span_branch, update, override?}, state) do
    {:noreply, edit_span_branch(state, update, override?)}
  end

  def handle_cast({:update_all_spans, update, override?}, state) do
    {:noreply, edit_all_spans(state, update, override?)}
  end

  def handle_cast({:publish, time}, state) do
    new_state = edit_all_spans(state, %{completion_time: time}, false)
    _ = do_publish(new_state)
    {:noreply, new_state}
  end

  def handle_cast(:stop, state) do
    GenServer.stop(self())

    {:noreply, state}
  end
end
defmodule Ockam.Hub.Service.PubSub do
  use Ockam.Worker

  alias __MODULE__.Topic
  alias Ockam.Message

  require Logger

  @impl true
  def setup(options, state) do
    prefix = Keyword.get(options, :prefix, state.address)
    {:ok, Map.put(state, :prefix, prefix)}
  end

  @impl true
  def handle_message(message, state) do
    payload = Message.payload(message)

    with {:ok, topic, ""} <- :bare.decode(payload, :string) do
      return_route = Message.return_route(message)
      subscribe(topic, return_route, state)
    else
      err ->
        Logger.error("Invalid message format: #{inspect(payload)}, reason #{inspect(err)}")
    end
  end

  def subscribe(topic, route, state) do
    with {:ok, worker} <- ensure_topic_worker(topic, state) do
      ## NOTE: Non-ockam message routing here
      Topic.subscribe(worker, route)
      {:ok, state}
    end
  end

  def ensure_topic_worker(topic, state) do
    topic_address = topic_address(topic, state)

    case Ockam.Node.whereis(topic_address) do
      nil -> Topic.create(topic: topic, address: topic_address)
      _pid -> {:ok, topic_address}
    end
  end

  def topic_address(topic, state) do
    Map.get(state, :prefix, "") <> "_" <> topic
  end
end

defmodule Ockam.Hub.Service.PubSub.Topic do
  use Ockam.Worker

  alias Ockam.Message

  def subscribe(worker, route) do
    Ockam.Worker.call(worker, {:subscribe, route})
  end

  @impl true
  def setup(options, state) do
    topic = Keyword.get(options, :topic)
    {:ok, Map.merge(state, %{topic: topic, routes: []})}
  end

  @impl true
  def handle_call({:subscribe, route}, _from, state) do
    {:reply, :ok, Map.update(state, :routes, [route], fn routes -> [route | routes] end)}
  end

  @impl true
  def handle_message(message, state) do
    [_me | onward_route] = Message.onward_route(message)

    state
    |> Map.get(:routes, [])
    |> Enum.each(fn route ->
      Ockam.Router.route(%{
        onward_route: route ++ onward_route,
        return_route: Message.return_route(message),
        payload: Message.payload(message)
      })
    end)

    {:ok, state}
  end
end

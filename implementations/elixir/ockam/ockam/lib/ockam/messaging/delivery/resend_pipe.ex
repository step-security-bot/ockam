defmodule Ockam.Messaging.Delivery.ResendPipe do
  @behaviour Ockam.Messaging.Pipe

  @impl true
  def sender() do
    __MODULE__.Sender
  end

  @impl true
  def receiver() do
    __MODULE__.Receiver
  end
end

defmodule Ockam.Messaging.Delivery.ResendPipe.Wrapper do
  @bare_schema {:struct, [ref: :uint, data: :data]}

  def wrap_message(message, ref) do
    case Ockam.Wire.encode(message) do
      {:ok, encoded_message} ->
        {:ok, :bare.encode(%{ref: ref, data: encoded_message}, @bare_schema)}

      error ->
        error
    end
  end

  def unwrap_message(wrapped) do
    with {:ok, %{ref: ref, data: encoded_message}, ""} <- :bare.decode(wrapped, @bare_schema),
         {:ok, message} <- Ockam.Wire.decode(encoded_message) do
      {:ok, ref, message}
    else
      {:ok, _decoded, _rest} = bare_result ->
        {:error, {:bare_decode_error, wrapped, bare_result}}
    end
  end
end

defmodule Ockam.Messaging.Delivery.ResendPipe.Sender do
  use Ockam.AsymmetricWorker

  require Logger

  alias Ockam.Messaging.Delivery.ResendPipe.Wrapper

  @default_confirm_timeout 5_000

  @impl true
  def inner_setup(options, state) do
    receiver_route = Keyword.get(options, :receiver_route)
    confirm_timeout = Keyword.get(options, :confirm_timeout, @default_confirm_timeout)

    {:ok,
     Map.merge(state, %{
       receiver_route: receiver_route,
       queue: [],
       confirm_timer: nil,
       confirm_timeout: confirm_timeout
     })}
  end

  ## TODO: batch send
  @impl true
  def handle_outer_message(message, state) do
    case waiting_confirm?(state) do
      true -> enqueue_message(message, state)
      false -> forward_to_receiver(message, state)
    end
  end

  @impl true
  def handle_inner_message(message, state) do
    case is_valid_confirm?(message, state) do
      true ->
        Logger.warn("confirm #{inspect(Map.get(state, :unconfirmed))}")
        confirm(state)

      false ->
        ## Ignore unknown confirms
        {:ok, state}
    end
  end

  @impl true
  def handle_non_message(:confirm_timeout, state) do
    resend_unconfirmed(state)
  end

  def resend_unconfirmed(state) do
    case Map.get(state, :unconfirmed) do
      nil ->
        {:stop, :cannot_resend_unconfirmed, state}

      message ->
        Logger.warn("resend #{inspect(message)}")
        clear_confirm_timeout(state)
        forward_to_receiver(message, state)
    end
  end

  def forward_to_receiver(message, state) do
    forwarded_message = make_forwarded_message(message)

    {ref, state} = bump_send_ref(state)
    {:ok, wrapped_message} = Wrapper.wrap_message(forwarded_message, ref)

    receiver_route = Map.get(state, :receiver_route)

    Ockam.Router.route(%{
      onward_route: receiver_route,
      return_route: [state.inner_address],
      payload: wrapped_message
    })

    {:ok, set_confirm_timeout(message, state)}
  end

  def bump_send_ref(state) do
    ref = Map.get(state, :send_ref, 0) + 1
    {ref, Map.put(state, :send_ref, ref)}
  end

  def make_forwarded_message(message) do
    [_me | onward_route] = Message.onward_route(message)

    %{
      onward_route: onward_route,
      return_route: Message.return_route(message),
      payload: Message.payload(message)
    }
  end

  def set_confirm_timeout(message, state) do
    timeout = Map.get(state, :confirm_timeout)
    timer_ref = Process.send_after(self(), :confirm_timeout, timeout)

    state
    |> Map.put(:confirm_timer, timer_ref)
    |> Map.put(:unconfirmed, message)
  end

  def clear_confirm_timeout(state) do
    case Map.get(state, :confirm_timer) do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        ## Flush the timeout message if it's already received
        receive do
          :confirm_timeout -> :ok
        after
          0 -> :ok
        end

        state
        |> Map.put(:confirm_timer, nil)
        |> Map.put(:unconfirmed, nil)
    end
  end

  def waiting_confirm?(state) do
    ## TODO: use unconfirmed here instead?
    case Map.get(state, :confirm_timer, nil) do
      nil -> false
      _timer -> true
    end
  end

  def is_valid_confirm?(message, state) do
    payload = Message.payload(message)
    {:ok, ref, ""} = :bare.decode(payload, :uint)

    case Map.get(state, :send_ref) do
      current_ref when current_ref == ref ->
        true

      other_ref ->
        Logger.info(
          "Received confirm for ref #{inspect(ref)}, current ref is #{inspect(other_ref)}"
        )

        false
    end
  end

  def enqueue_message(message, state) do
    Logger.warn("enqueue #{inspect(message)}")
    queue = Map.get(state, :queue, [])
    {:ok, Map.put(state, :queue, queue ++ [message])}
  end

  def confirm(state) do
    queue = Map.get(state, :queue, [])

    case queue do
      [message | rest] ->
        forward_to_receiver(message, Map.put(state, :queue, rest))

      [] ->
        {:ok, clear_confirm_timeout(state)}
    end
  end
end

defmodule Ockam.Messaging.Delivery.ResendPipe.Receiver do
  @moduledoc """
  Receiver part of the resend pipe.

  Received wrapped messages with confirm refs
  Unwraps and forwards messages
  Sends confirm messages with confirm ref to the message sender
  """
  use Ockam.Worker

  alias Ockam.Message
  alias Ockam.Router

  alias Ockam.Messaging.Delivery.ResendPipe.Wrapper

  require Logger

  @impl true
  def handle_message(message, state) do
    return_route = Message.return_route(message)
    wrapped_message = Message.payload(message)

    case Wrapper.unwrap_message(wrapped_message) do
      {:ok, ref, message} ->
        Router.route(message)
        send_confirm(ref, return_route, state)
        {:ok, state}

      {:error, err} ->
        Logger.error("Error unwrapping message: #{inspect(err)}")
        {:error, err}
    end
  end

  def send_confirm(ref, return_route, state) do
    Router.route(%{
      onward_route: return_route,
      return_route: [state.address],
      payload: ref_payload(ref)
    })
  end

  def ref_payload(ref) do
    :bare.encode(ref, :uint)
  end
end

# Supervisor
#   -> BotSupervisor       -> Boobot (use Bot) 
#   -> ResponderSupervisor -> Hello (use Blur.Responder)

#   Bot
#     {Blur.Bot, [name: "800807", responders: [Boobot.Responder]]}

#   Responder (dynamic supervisor)

#     start_new_responder(Boobot.Responder, {Bot, channels: "#rockerboo"})

#     Responder

#     Any responders?
#     Any matches?

#   Twitch
#     IRC

defmodule Blur.Message do
  defstruct text: ""
end

defmodule Blur.Notice do
  defstruct text: ""
end

defmodule Blur.Adapter do
  @doc false
  defmacro __using__(_opts) do
    quote do
      import Kernel, except: [send: 2]

      @behaviour Blur.Adapter
      use GenServer

      def send(pid, %Blur.Message{} = msg) do
        GenServer.cast(pid, {:send, msg})
      end

      @doc false
      @spec start_link(bot :: Blur.Bot.process(), opts :: keyword) :: GenServer.on_start()
      def start_link(bot, opts) do
        Blur.Adapter.start_link(__MODULE__, opts)
      end

      @doc false
      @spec stop(Blur.Bot.process(), integer) :: :ok
      def stop(pid, timeout \\ 5000) do
        ref = Process.monitor(pid)
        Process.exit(pid, :normal)

        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          timeout -> exit(:timeout)
        end

        :ok
      end

      @doc false
      defmacro __before_compile__(_env) do
        :ok
      end

      defoverridable __before_compile__: 1, send: 2
    end
  end

  @doc false
  @spec start_link(Blur.Bot.process(), opts :: keyword) :: GenServer.on_start()
  def start_link(module, opts) do
    GenServer.start_link(module, {self(), opts})
  end

  @type bot :: Blur.Bot.process()
  @type opts :: any
  @type msg :: Blur.Message.t()

  @callback send(pid, msg) :: term
end

defmodule Blur.Adapter.IRC do
  require Logger
  alias ExIRC.Client

  use Blur.Adapter

  @spec init({Blur.Bot.process(), keyword}) ::
          {:ok, {Blur.Bot.process(), opts :: keyword, client :: pid}}
  def init({bot, opts}) do
    Logger.debug("#{inspect(opts)}")

    {:ok, client} = ExIRC.start_client!()
    Client.add_handler(client, self())

    Kernel.send(self(), :connect)
    {:ok, {bot, opts, client}}
  end
end

defmodule Blur.Bot do
  @moduledoc """
  Bot controls for you to use to make your own bot.

  ## Example

  defmodule MyBot.Bot do 
    use Blur.Bot
  end
  """

  require Logger

  alias Blur.Bot
  alias Blur.Message
  alias Blur.Notice
  alias Blur.Responder

  defstruct responders: [],
            adapter: nil,
            name: "",
            opts: []

  @typedoc "User bot process."
  @type process :: pid | atom

  # Macro to add bot functionality. 
  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      use GenServer

      @otp_app __MODULE__
      @adapter Blur.Adapter.IRC

      def __adapter__, do: @adapter

      @spec start_link(keyword) :: Supervisor.on_start_child()
      def start_link(opts \\ []) do
        Blur.Bot.start_bot(__MODULE__, opts)
      end

      @def false
      @impl true
      @spec init(list) :: {:ok, %Bot{}}
      def init([name, channel, responders] = opts) do
        {:ok, adapter} = @adapter.start_link(self(), opts)

        Kernel.send(self(), :connect)

        {:ok,
         %Blur.Bot{
           adapter: adapter,
           name: name,
           opts: opts
         }}
      end

      @def """
      Handle connections to the Adapter service.
      """
      @spec handle_connect(%Bot{}) :: {:ok, %Bot{}}
      def handle_connect(state) do
        {:ok, state}
      end

      @def """
      Handle disconnections to the Adapter service.
      """
      @spec handle_disconnect(reason :: String.t(), %Bot{}) :: {:reconnect, %Bot{}}
      def handle_disconnect(_reason, state) do
        # Auto respond with a reconnect.
        {:reconnect, state}
      end

      @def """
      Handle new messages
      """
      @spec handle_in(%Message{} | %Notice{}, %Bot{}) ::
              {:dispatch, %Message{} | %Notice{}, %Bot{}}

      def handle_in(%Message{} = msg, state) do
        {:dispatch, msg, state}
      end

      def handle_in(%Notice{} = notice, state) do
        {:dispatch, notice, state}
      end

      @impl true
      def handle_call(_msg, _from, state) do
        {:reply, :ok, state}
      end

      @impl true
      def handle_cast(_msg, state) do
        {:noreply, state}
      end

      @def false
      @impl true
      def handle_info(_msg, state) do
        {:noreply, state}
      end

      @def false
      @impl true
      def terminate(_reason, _state) do
        :ok
      end

      @def false
      @impl true
      def code_change(_old, state, _extra) do
        {:ok, state}
      end

      # def child_spec(opts) do
      #   %{
      #     id: __MODULE__,
      #     start: {__MODULE__, :start_link, [opts]},
      #     type: :worker,
      #     restart: :temporary
      #   }
      # end

      defoverridable [
        {:handle_connect, 1},
        {:handle_disconnect, 2},
        {:handle_in, 2},
        {:terminate, 2},
        {:code_change, 3},
        {:handle_info, 2}
      ]
    end
  end

  def child_spec([bot, opts] = args) do
    IO.inspect(__MODULE__)
    IO.inspect(args)

    %{
      id: bot,
      start: {bot, :start_link, [opts]}
    }
  end

  @spec start_link(bot :: Bot.process(), opts :: keyword) :: GenServer.on_start()
  def start_link(bot, opts) do
    # Starts the bot. Bots are started using their module name (which is an atom)
    GenServer.start_link(bot, {bot, opts})
  end

  @doc """
  Send a message via the bot.
  """
  @spec send(pid, %Blur.Message{}) :: :ok
  def send(pid, msg) do
    GenServer.cast(pid, {:send, msg})
  end

  @doc """
  Get the name of the bot. 
  """
  @spec name(pid) :: term
  def name(pid) do
    GenServer.call(pid, :name)
  end

  @doc """
  Handle incoming bot messages.
  """
  @spec handle_in(bot :: Bot.process(), %Message{}) :: :ok
  def handle_in(bot, msg) do
    GenServer.cast(bot, {:handle_in, msg})
  end

  @doc """
  Handle connection events.
  """
  @spec handle_connect(Blur.Bot.process()) :: term
  def handle_connect(bot) do
    GenServer.call(bot, :handle_connect)
  end

  @doc """
  Handle disconnection events.
  """
  @spec handle_disconnect(Blur.Bot.process(), reason :: binary) :: term
  def handle_disconnect(bot, reason) do
    GenServer.call(bot, {:handle_disconnect, reason})
  end

  # Stop the bot
  # ---
  # Stop the bot by removing it from the Bot Supervisor
  @spec stop_bot(bot :: Blur.Bot.process()) :: :ok | {:error, :not_found}
  def stop_bot(bot) when is_pid(bot) do
    DynamicSupervisor.terminate_child(Bot.Supervisor, bot)
  end

  def stop_bot(bot) do
    case Process.whereis(bot) do
      pid when is_pid(pid) -> stop_bot(pid)
      _ -> {:error, :not_found}
    end
  end

  # Start the bot
  # ---
  # The main entry point to start the bot. Adds it to the supervisor. 
  @spec start_bot(atom(), keyword) :: DynamicSupervisor.on_start_child()
  def start_bot(bot, opts) do
    opts
    |> Keyword.fetch!(:responders)
    |> Enum.each(fn resp ->
      {:ok, _} = DynamicSupervisor.start_child(Responder.Supervisor, {resp, []})
    end)

    IO.inspect(opts)
    Logger.info("Starting the bot. #{bot}")

    DynamicSupervisor.start_child(Bot.Supervisor, {Blur.Bot, [bot, opts]})
  end
end

defmodule Blur.Responder do
  @moduledoc """
  Responder to messages. Use this to make your own Responders

  ## Example:

  defmodule MyBot.Hello do 
    use Blur.Responder
  end
  """

  @typedoc "Responder States"
  @type t :: keyword | list | map

  defstruct bot: nil

  @type process :: pid | atom

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      use GenServer

      alias Blur.Message

      @spec hear(%Message{}, Blur.Responder.t()) :: {:dispatch, %Message{}, Blur.Responder.t()}
      def hear(%Message{} = msg, state) do
        {:dispatch, msg, state}
      end

      @impl true
      def init([]) do
        {:ok, []}
      end

      @impl true
      def handle_call(_msg, _from, _state) do
        {:noreply, :ok}
      end

      @impl true
      def handle_cast(_msg, _state) do
        {:noreply, :ok}
      end
    end
  end
end

defmodule Blur.ResponderExample do
  use Blur.Responder
end

defmodule Blur.BotExample do
  use Blur.Bot, otp_app: Blur.BotExample
end

defmodule Blur.Supervisor do
  use Supervisor

  def start!() do
  end

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: Blur.Bot.Supervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Blur.Responder.Supervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Blur.App do
  use Application

  def start(_type, _args) do
    Blur.Supervisor.start_link([])
  end
end

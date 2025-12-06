Mix.install([
  {:req, "~> 0.5"}
])

defmodule NextDns do
  @api_key System.fetch_env!("NEXT_DNS_API_KEY")
  @profile_id System.fetch_env!("NEXT_DNS_PROFILE_ID")
  @base_url "https://api.nextdns.io"

  def get_denylist() do
    response =
      Req.get!(
        "#{@base_url}/profiles/#{@profile_id}/denylist",
        headers: [
          {"x-api-key", @api_key}
        ]
      )

    case response.status do
      200 -> Map.get(response.body, "data")
      _ -> {:error, "Failed to fetch denylist. Status: #{response.status}"}
    end
  end

  def get_disabled_denylist_items() do
    get_denylist()
    |> Enum.reject(fn deny_item -> Map.get(deny_item, "active") end)
    |> Enum.map(fn deny_item -> Map.get(deny_item, "id") end)
    |> Enum.join(",")
    |> then(fn items -> "NextDns denylist items are disabled: #{items}" end)
  end
end

defmodule Pushover do
  @pushover_token System.fetch_env!("PUSHOVER_TOKEN")
  @pushover_user System.fetch_env!("PUSHOVER_USER")

  def send_message(""), do: :ok

  def send_message(message) do
    dbg(message)

    params = %{
      message: message,
      priority: 1,
      device: "DeWet-Phone",
      sound: "siren",
      token: @pushover_token,
      user: @pushover_user
    }

    Req.post!(
      "https://api.pushover.net/1/messages.json",
      json: params
    )

    sleep_milliseconds = 1000 * 60 * 10
    dbg("😴 Sleeping for #{sleep_milliseconds} milliseconds 😴")
    Process.sleep(sleep_milliseconds)
  end
end

defmodule Runner do
  def run() do
    NextDns.get_disabled_denylist_items()
    |> Pushover.send_message()

    Process.sleep(2000)
    run()
  end
end

children = [
  {Task.Supervisor, name: Allow.TaskSupervisor}
]

Supervisor.start_link(children, strategy: :one_for_one)

Task.Supervisor.async(Allow.TaskSupervisor, fn ->
  dbg("Starting Allow 🏁")
  Runner.run()
end)

Process.sleep(:infinity)

Mix.install([
  {:req, "~> 0.5"}
])

defmodule NextDns do
  @api_key System.fetch_env!("NEXT_DNS_API_KEY")
  @profile_id System.fetch_env!("NEXT_DNS_PROFILE_ID")
  @base_url "https://api.nextdns.io"

  def get_messages() do
    get_disabled_denylist_items()
  end

  defp get_disabled_denylist_items() do
    get_denylist()
    |> Enum.reject(fn deny_item -> Map.get(deny_item, "active") end)
    |> Enum.map(fn deny_item -> Map.get(deny_item, "id") end)
    |> Enum.join(",")
    |> then(fn items ->
      case items do
        "" ->
        dbg("✅ All NextDns denylist items enabled ✅")
        nil
        _ ->
        "NextDns denylist items are disabled: #{items}"
      end
    end)
  end

  defp get_denylist() do
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
end

defmodule Unifi do
  @unifi_username System.fetch_env!("UNIFI_USERNAME")
  @unifi_password System.fetch_env!("UNIFI_PASSWORD")
  @skipped_networks ["Tulia DMZ", "Productivity Palace 🏯", "The Fort 🏰"]
  @controller_ip "10.0.0.10"
  @port 8443
  @site "default"

  def get_messages() do
    get_networks_without_mac_address_filters()
  end

  def get_networks_without_mac_address_filters() do
    with {:ok, cookie} <- login(),
         {:ok, wlan_confs} <- get_wlan_confs(cookie) do
      _ = logout(cookie)

      misconfigured =
        wlan_confs
        |> Enum.reject(fn wlan ->
          network_name = wlan["name"] || wlan["ssid"] || ""
          Enum.member?(@skipped_networks, network_name)
        end)
        |> Enum.reject(fn wlan ->
          wlan["mac_filter_enabled"] == true && wlan["mac_filter_policy"] in ["allow", :allow]
        end)
        |> Enum.map(fn wlan -> wlan["name"] || wlan["ssid"] || "Unknown" end)

      case misconfigured do
        [] ->
          dbg("✅ All UniFi networks have MAC address allow list enabled ✅")
          nil
        networks -> "UniFi networks without MAC address allow list: #{Enum.join(networks, ", ")}"
      end
    else
      {:error, _reason} -> nil
    end
  end

  defp req_options do
    [
      connect_options: [
        transport_opts: [
          verify: :verify_none,
          verify_fun: {fn _, _, _ -> {:valid, :undefined} end, :undefined},
          fail_if_no_peer_cert: false,
          versions: [:"tlsv1.2", :"tlsv1.3"]
        ]
      ],
      receive_timeout: 10_000
    ]
  end

  defp req_headers(:login) do
    [
      {"Accept", "application/json"},
      {"Content-Type", "application/json"}
    ]
  end

  defp req_headers(:authenticated, cookie) do
    [
      {"Content-Type", "application/json"},
      {"Cookie", cookie}
    ]
  end

  defp login() do
    url = "https://#{@controller_ip}:#{@port}/api/login"

    body =
      JSON.encode!(%{
        username: @unifi_username,
        password: @unifi_password,
        remember: false
      })

    case Req.post(url, [body: body, headers: req_headers(:login)] ++ req_options()) do
      {:ok, %Req.Response{status: 200, headers: response_headers}} ->
        cookie = extract_cookie(response_headers)

        if cookie == "" do
          {:error, "Failed to retrieve session cookie from login response"}
        else
          {:ok, cookie}
        end

      {:ok, %Req.Response{status: status_code, body: response_body}} ->
        {:error, "Login failed with status #{status_code}: #{inspect(response_body)}"}

      {:error, reason} ->
        {:error, "HTTP error during login: #{inspect(reason)}"}
    end
  end

  defp logout(cookie) do
    url = "https://#{@controller_ip}:#{@port}/api/logout"
    _ = Req.post(url, [body: "{}", headers: req_headers(:authenticated, cookie)] ++ req_options())
    :ok
  end

  defp extract_cookie(headers) do
    case Map.get(headers, "set-cookie") do
      cookie_value when is_binary(cookie_value) ->
        cookie_value |> String.split(";") |> List.first()

      cookie_list when is_list(cookie_list) ->
        cookie_list |> List.first() |> String.split(";") |> List.first()

      _ ->
        ""
    end
  end

  defp get_wlan_confs(cookie) do
    url = "https://#{@controller_ip}:#{@port}/api/s/#{@site}/rest/wlanconf"

    case Req.get(url, [headers: req_headers(:authenticated, cookie)] ++ req_options()) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) ->
        {:ok, data}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:error, "Unexpected WLAN response format: #{inspect(body)}"}

      {:ok, %Req.Response{status: status_code}} ->
        {:error, "WLAN request failed with status #{status_code}"}

      {:error, reason} ->
        {:error, "HTTP error during WLAN request: #{inspect(reason)}"}
    end
  end
end

defmodule Pushover do
  @pushover_token System.fetch_env!("PUSHOVER_TOKEN")
  @pushover_user System.fetch_env!("PUSHOVER_USER")

  def send_message(nil), do: :ok

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
    NextDns.get_messages()
    |> Pushover.send_message()

    Unifi.get_messages()
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

defmodule AbsintheWebSocket.Mixfile do
  use Mix.Project

  @version "0.2.3"
  @url "https://github.com/karlosmid/absinthe_websocket"
  @maintainers [
    "Karlo Šmid",
  ]

  def project do
    [
      app: :absinthe_websocket_hr,
      version: @version,
      elixir: "~> 1.5",
      start_permanent: Mix.env == :prod,
      deps: deps(),
      aliases: aliases(),
      description: "Communicate with a Absinthe+Phoenix Endpoint over WebSockets",
      docs: docs(),
      package: package(),
      source_url: @url,
      homepage_url: @url,
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:websockex, "~> 0.4"},
      {:poison, "~> 2.0 or ~> 3.0 or ~> 4.0"},
      {:ex_doc, "~> 0.28", only: :dev},
    ]
  end

  def docs do
    [
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp package do
    [
      name: :absinthe_websocket_hr,
      maintainers: @maintainers,
      licenses: ["MIT"],
      links: %{github: @url},
      files: ["lib", "mix.exs", "README*", "LICENSE*", "CHANGELOG.md"],
    ]
  end

  defp aliases do
    [publish: ["hex.publish", &git_tag/1]]
  end

  defp git_tag(_args) do
    System.cmd "git", ["tag", "v" <> Mix.Project.config[:version]]
    System.cmd "git", ["push", "--tags"]
  end
end

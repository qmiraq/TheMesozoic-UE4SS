MesozoicWeatherController alpha v0.1.5
========================================

Lightweight custom weather controller for The Mesozoic EVRIMA server.

Used weather presets:
  - Clear Sky
  - Cloudy
  - Foggy
  - Light Rain
  - Rain
  - Rain Extension (uses the normal Rain preset)

Unused weather presets:
  - Partly Cloud
  - Overcast
  - Thunderstorm
  - Heavy Rain

State graph:
  Clear Sky (10-15m)
    50% remain Clear Sky
    50% Cloudy

  Cloudy (3-6m)
    1/3 Clear Sky
    1/3 Foggy -> Cloudy -> Clear Sky
    1/3 Light Rain

  Light Rain (3-6m)
    1/3 Cloudy -> Clear Sky
    2/3 Rain

  Rain (3-6m)
    1/2 Rain Extension (3-6m) -> Light Rain -> Cloudy -> Clear Sky
    1/2 Light Rain -> Cloudy -> Clear Sky

The controller calls Ultra Dynamic Weather's native Change Weather function so
visual transitions are replicated to players. If that reflected function is
unavailable, it uses the transition fields observed from the in-game panel.
Weather preset packages are loaded on demand before applying them.

The controller disables The Isle's native random-weather flag and UDW random
variation state while active. It also corrects any native preset drift left by
an already-scheduled game weather timer.
It performs one lightweight timer check per second and searches for the weather
actor only when changing weather, verifying a change, or running its 5-second
native-random guard.

Configuration:
  Mods\MesozoicWeatherController\config\WeatherController.ini

Diagnostics:
  Mods\MesozoicWeatherController\Saved\weather_controller_events.ndjson
  Mods\MesozoicWeatherController\Saved\weather_controller_status.json

The old MesozoicWeatherProbe must remain disabled during normal operation.

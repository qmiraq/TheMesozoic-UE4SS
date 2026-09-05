MesozoicWeatherProbe alpha v0.2.0
===================================

This is an observation-only UE4SS Lua probe for The Isle EVRIMA.

It records calls to:
  - TIGameModeBase:SetWeather
  - TIGameModeBase:SetClearSky
  - TIWeatherActor:SetRainIntensity

It also samples the live TIWeatherActor once per second and records changes to
primitive and UObject-reference properties declared by its Blueprint class and
TIWeatherActor. UObject references are written as names and are never retained.

It does not call those functions and cannot change the weather or player state.

Output:
  Mods\MesozoicWeatherProbe\Saved\weather_state_probe_events.ndjson

The same observations are mirrored into UE4SS.log with the prefix:
  [MesozoicWeatherProbe]

Test by manually choosing Clear Sky and every available weather option once
through the in-game admin panel. Wait at least 10 seconds between selections.

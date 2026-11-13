-- Tiny UI string table. The plugin follows the system locale when it is
-- Spanish, and can be forced with SPOTATUI_LYRICS_LANG=en|es.

local M = {}

local STRINGS = {
  en = {
    screen_title = "Lyrics",
    nothing_playing = "Nothing is playing",
    loading = "Looking up lyrics…",
    empty = "No lyrics found for this track",
    not_music = "This looks like a non-music video",
    disabled = "This source is not enabled for the plugin",
    idle = "Nothing is playing",
    synced = "synced",
    estimated = "text · estimated",
    text = "text",
    low_confidence = "low confidence",
    provider = "Source",
    offset = "offset",
    match = "match",
    follow = "following",
    follow_paused = "scroll paused",
    keys = "j/k scroll · f follow · s seek · [ ] offset · m match · r retry · i info · Esc back",
    keys_compact = "j/k · f · s · [ ] · m · r · 0 · i · Esc",
    seek_hint = "s: seek to the selected line",
    loading_hint = "The first lookup can take a few seconds",
    empty_hint = "r retry · m try another match · i details",
    not_music_hint = "r search anyway · i details",
    debug_title = "Lyrics debug",
    refresh = "Lyrics refreshed",
    offset_changed = "Offset %+d ms",
    offset_reset = "Offset reset",
    match_changed = "Match %d/%d",
    no_track = "No track is playing",
    progress = "%s / %s",
    details = "Details",
    source_line = "%s · %s",
    variant = "match %d/%d",
    line_count = "%d lines",
    timeout = "lookup timed out",
    errors = "Errors",
    more = "…",
  },
  es = {
    screen_title = "Letras",
    nothing_playing = "No hay nada reproduciéndose",
    loading = "Buscando letras…",
    empty = "No se encontraron letras para este tema",
    not_music = "Esto parece un vídeo que no es una canción",
    disabled = "Esta fuente no está habilitada para el plugin",
    idle = "No hay nada reproduciéndose",
    synced = "sincronizada",
    estimated = "texto · estimado",
    text = "texto",
    low_confidence = "dudosa",
    provider = "Fuente",
    offset = "desfase",
    match = "coincidencia",
    follow = "siguiendo",
    follow_paused = "scroll manual",
    keys = "j/k mover · f seguir · s ir a la línea · [ ] desfase · m otra coincidencia · r reintentar · i info · Esc volver",
    keys_compact = "j/k · f · s · [ ] · m · r · 0 · i · Esc",
    seek_hint = "s: saltar a la línea seleccionada",
    loading_hint = "La primera búsqueda puede tardar unos segundos",
    empty_hint = "r reintentar · m probar otra coincidencia · i detalles",
    not_music_hint = "r buscar igualmente · i detalles",
    debug_title = "Depuración de letras",
    refresh = "Letras actualizadas",
    offset_changed = "Desfase %+d ms",
    offset_reset = "Desfase restablecido",
    match_changed = "Coincidencia %d/%d",
    no_track = "No se está reproduciendo nada",
    progress = "%s / %s",
    details = "Detalles",
    source_line = "%s · %s",
    variant = "coincidencia %d/%d",
    line_count = "%d líneas",
    timeout = "la búsqueda agotó el tiempo",
    errors = "Errores",
    more = "…",
  },
}

local function detect_language()
  local forced = os.getenv("SPOTATUI_LYRICS_LANG")
  if forced and STRINGS[forced:lower()] then
    return forced:lower()
  end
  local locale = os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or os.getenv("LANG") or ""
  if locale:lower():sub(1, 2) == "es" then
    return "es"
  end
  return "en"
end

M.lang = detect_language()

function M.t(key)
  local table_for_lang = STRINGS[M.lang] or STRINGS.en
  return table_for_lang[key] or STRINGS.en[key] or key
end

function M.fmt(key, ...)
  local ok, value = pcall(string.format, M.t(key), ...)
  if ok then
    return value
  end
  return M.t(key)
end

return M

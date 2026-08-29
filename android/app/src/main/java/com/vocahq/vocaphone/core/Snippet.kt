package com.vocahq.vocaphone.core

import org.json.JSONArray
import org.json.JSONObject

/** A user-defined trigger phrase and the literal text it expands into. */
data class Snippet(
    val id: String,
    val trigger: String,
    val expansion: String,
) {
    private fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("trigger", trigger)
        put("expansion", expansion)
    }

    companion object {
        fun encode(snippets: List<Snippet>): String =
            JSONArray(snippets.map { it.toJson() }).toString()

        // Corrupt or unreadable storage becomes no snippets rather than a
        // crash on every dictation and every settings screen open.
        fun decode(stored: String?): List<Snippet> {
            if (stored.isNullOrBlank()) return emptyList()
            return runCatching {
                val array = JSONArray(stored)
                List(array.length()) { index ->
                    val entry = array.getJSONObject(index)
                    Snippet(
                        id = entry.getString("id"),
                        trigger = entry.getString("trigger"),
                        expansion = entry.getString("expansion"),
                    )
                }
            }.getOrDefault(emptyList())
        }
    }
}

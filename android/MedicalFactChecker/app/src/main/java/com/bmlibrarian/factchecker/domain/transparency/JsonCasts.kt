package com.bmlibrarian.factchecker.domain.transparency

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull

/**
 * Reads untyped JSON the way Swift's `as?` casts read `JSONSerialization` output.
 *
 * The Swift CrossRef and ClinicalTrials.gov clients parse responses into
 * `[String: Any]` and pick fields with conditional casts. Two properties of
 * those casts decide what a field reads as, and both are kept here so the two
 * platforms parse a response identically:
 *  - a cast of the wrong kind yields nothing: a number is not a string, a
 *    string is not a bool;
 *  - an array cast is all-or-nothing: `as? [String]` on an array holding one
 *    non-string yields nothing at all, not the strings it does hold.
 */
object JsonCasts {

    /**
     * A JSON string's content (Swift `as? String`).
     *
     * @param element The element, or null when the key is absent.
     * @return The string, or null for any other kind of value.
     */
    fun string(element: JsonElement?): String? =
        (element as? JsonPrimitive)?.takeIf { it.isString }?.content

    /**
     * A JSON boolean (Swift `as? Bool`).
     *
     * @param element The element, or null when the key is absent.
     * @return The boolean, or null for a string or any other kind of value.
     */
    fun boolean(element: JsonElement?): Boolean? =
        (element as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.booleanOrNull

    /**
     * A JSON integer (Swift `as? Int`).
     *
     * @param element The element, or null when the key is absent.
     * @return The integer, or null for a string, a non-integral number or any other value.
     */
    fun int(element: JsonElement?): Int? =
        (element as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.intOrNull

    /**
     * A JSON object (Swift `as? [String: Any]`).
     *
     * @param element The element, or null when the key is absent.
     * @return The object, or null for any other kind of value.
     */
    fun obj(element: JsonElement?): JsonObject? = element as? JsonObject

    /**
     * An array of strings, all or nothing (Swift `as? [String]`).
     *
     * @param element The element, or null when the key is absent.
     * @return The strings, or null if [element] is not an array or holds any non-string.
     */
    fun stringList(element: JsonElement?): List<String>? = allOrNothing(element) { string(it) }

    /**
     * An array of objects, all or nothing (Swift `as? [[String: Any]]`).
     *
     * @param element The element, or null when the key is absent.
     * @return The objects, or null if [element] is not an array or holds any non-object.
     */
    fun objectList(element: JsonElement?): List<JsonObject>? = allOrNothing(element) { obj(it) }

    /**
     * An array of integer arrays, all or nothing (Swift `as? [[Int]]`).
     *
     * @param element The element, or null when the key is absent.
     * @return The integer arrays, or null if any level holds a value of another kind.
     */
    fun intListList(element: JsonElement?): List<List<Int>>? =
        allOrNothing(element) { inner -> allOrNothing(inner) { int(it) } }

    /** Cast every element of a JSON array with [cast], failing the whole array if any cast fails. */
    private fun <T : Any> allOrNothing(element: JsonElement?, cast: (JsonElement) -> T?): List<T>? {
        val array = element as? JsonArray ?: return null
        val values = array.map { cast(it) ?: return null }
        return values
    }
}

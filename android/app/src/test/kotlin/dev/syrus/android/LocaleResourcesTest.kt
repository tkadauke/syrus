package dev.syrus.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import java.util.Locale
import javax.xml.parsers.DocumentBuilderFactory

class LocaleResourcesTest {
    @Test
    fun germanAndLatinCatalogsMatchEnglishKeysPlaceholdersAndPluralQuantities() {
        val english = catalog("values")

        listOf("values-de", "values-la").forEach { directory ->
            val localized = catalog(directory)
            assertEquals("String keys differ in $directory", english.strings.keys, localized.strings.keys)
            assertEquals("Plural keys differ in $directory", english.plurals.keys, localized.plurals.keys)

            english.strings.forEach { (key, value) ->
                assertEquals("Placeholders differ for $key in $directory", placeholders(value), placeholders(localized.strings.getValue(key)))
            }
            english.plurals.forEach { (key, quantities) ->
                val localizedQuantities = localized.plurals.getValue(key)
                assertEquals("Plural quantities differ for $key in $directory", quantities.keys, localizedQuantities.keys)
                quantities.forEach { (quantity, value) ->
                    assertEquals(
                        "Placeholders differ for $key[$quantity] in $directory",
                        placeholders(value),
                        placeholders(localizedQuantities.getValue(quantity)),
                    )
                }
            }
        }
    }

    @Test
    fun representativeGermanAndLatinFormatsRenderArguments() {
        val german = catalog("values-de")
        val latin = catalog("values-la")

        val germanStatus = String.format(
            Locale.GERMAN,
            german.plurals.getValue("signed_in_job_count").getValue("other"),
            "anna@example.test",
            2,
        )
        val latinError = String.format(
            Locale.forLanguageTag("la"),
            latin.strings.getValue("api_http_error"),
            503,
        )

        assertEquals("Angemeldet als anna@example.test · 2 Jobs", germanStatus)
        assertEquals("Petitio API Syri HTTP 503 defecit.", latinError)
    }

    private fun catalog(directory: String): Catalog {
        val file = File("src/main/res/$directory/strings.xml")
        assertTrue("Missing locale catalog: $file", file.isFile)
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val strings = linkedMapOf<String, String>()
        val plurals = linkedMapOf<String, Map<String, String>>()
        val children = document.documentElement.childNodes

        for (index in 0 until children.length) {
            val element = children.item(index) as? Element ?: continue
            when (element.tagName) {
                "string" -> strings[element.getAttribute("name")] = element.textContent
                "plurals" -> {
                    val quantities = linkedMapOf<String, String>()
                    val items = element.childNodes
                    for (itemIndex in 0 until items.length) {
                        val item = items.item(itemIndex) as? Element ?: continue
                        if (item.tagName == "item") quantities[item.getAttribute("quantity")] = item.textContent
                    }
                    plurals[element.getAttribute("name")] = quantities
                }
            }
        }

        return Catalog(strings, plurals)
    }

    private fun placeholders(value: String): List<String> {
        return PLACEHOLDER.findAll(value).map { it.value }.sorted().toList()
    }

    private data class Catalog(
        val strings: Map<String, String>,
        val plurals: Map<String, Map<String, String>>,
    )

    private companion object {
        val PLACEHOLDER = Regex("%\\d+\\$[a-zA-Z]")
    }
}

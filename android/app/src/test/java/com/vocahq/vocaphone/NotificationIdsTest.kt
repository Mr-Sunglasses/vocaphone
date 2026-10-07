package com.vocahq.vocaphone

import java.lang.reflect.Modifier
import org.junit.Assert.assertEquals
import org.junit.Test

class NotificationIdsTest {
    @Test
    fun `every notification has its own id`() {
        // Two notifications sharing an id replace each other, whatever channel
        // they are on: the model download and the bubble notice once did.
        assertEquals(NotificationIds.all.size, NotificationIds.all.toSet().size)
    }

    @Test
    fun `every declared id is in the checked list`() {
        // A constant added without listing it in `all` would skip the check
        // above. The const vals compile to static int fields on the object;
        // `$`-prefixed ones are compiler-generated (Compose's `$stable`).
        val declared = NotificationIds::class.java.declaredFields
            .filter { Modifier.isStatic(it.modifiers) && it.type == Int::class.javaPrimitiveType }
            .filterNot { it.isSynthetic || it.name.startsWith("$") }
            .associate { it.name to it.getInt(null) }
        assertEquals(declared.values.sorted(), NotificationIds.all.sorted())
    }
}

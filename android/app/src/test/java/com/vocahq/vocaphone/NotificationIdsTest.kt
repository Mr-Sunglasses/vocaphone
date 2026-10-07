package com.vocahq.vocaphone

import org.junit.Assert.assertEquals
import org.junit.Test

class NotificationIdsTest {
    @Test
    fun `every notification has its own id`() {
        // Two notifications sharing an id replace each other, whatever channel
        // they are on: the model download and the bubble notice once did.
        assertEquals(NotificationIds.all.size, NotificationIds.all.toSet().size)
    }
}

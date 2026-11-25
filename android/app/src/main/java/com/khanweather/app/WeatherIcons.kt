package com.khanweather.app

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import com.khanweather.core.WeatherCondition
import com.khanweather.core.WeatherCondition.*
import kotlin.math.cos
import kotlin.math.sin

/**
 * Full-colour weather symbols drawn in code (yellow sun, white clouds, blue rain, yellow
 * lightning), so the app and the widgets draw exactly the same art. Coordinates are in a
 * 100-unit box scaled to the requested size.
 */
object WeatherIcons {
    private const val SUN = 0xFFFFC928.toInt()
    private const val MOON = 0xFFF4EBC4.toInt()
    private const val CLOUD = 0xFFFFFFFF.toInt()
    private const val CLOUD_BACK = 0xFFC9D3E0.toInt()
    private const val RAIN = 0xFF3CE8FF.toInt()
    private const val ICE = 0xFF5FE0E0.toInt()
    private const val SNOW = 0xFFE8F6FF.toInt()
    private const val BOLT = 0xFFFFD60A.toInt()

    fun bitmap(condition: WeatherCondition, isDay: Boolean, px: Int, heavy: Boolean = false, mixed: Boolean = false): Bitmap {
        val bmp = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
        draw(Canvas(bmp), px.toFloat(), condition, isDay, heavy, mixed)
        return bmp
    }

    fun draw(canvas: Canvas, size: Float, condition: WeatherCondition, isDay: Boolean, heavy: Boolean = false, mixed: Boolean = false) {
        canvas.save()
        canvas.scale(size / 100f, size / 100f)
        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
        val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
        }
        val effective = if (mixed && condition.isPrecipitation) freezingRain else condition
        when (effective) {
            clear -> if (isDay) sun(canvas, 50f, 50f, 22f, fill, stroke) else moon(canvas, 50f, 50f, 26f, fill)
            mainlyClear, partlyCloudy -> {
                if (isDay) sun(canvas, 38f, 38f, 16f, fill, stroke) else moon(canvas, 38f, 36f, 19f, fill)
                cloud(canvas, 58f, 66f, if (condition == mainlyClear) 0.7f else 0.85f, CLOUD, fill)
            }
            overcast, unknown -> {
                cloud(canvas, 40f, 44f, 0.75f, CLOUD_BACK, fill)
                cloud(canvas, 56f, 60f, 0.95f, CLOUD, fill)
            }
            fog -> {
                cloud(canvas, 50f, 42f, 0.95f, CLOUD, fill)
                stroke.color = CLOUD; stroke.strokeWidth = 6f
                canvas.drawLine(18f, 72f, 82f, 72f, stroke)
                canvas.drawLine(26f, 86f, 74f, 86f, stroke)
            }
            drizzle -> { cloud(canvas, 50f, 40f, 0.95f, CLOUD, fill); drops(canvas, RAIN, short = true, stroke) }
            rain, rainShowers -> {
                if (condition == rainShowers && isDay && !heavy) sun(canvas, 70f, 26f, 12f, fill, stroke)
                cloud(canvas, 50f, if (heavy) 36f else 40f, 0.95f, CLOUD, fill); drops(canvas, RAIN, short = false, stroke, heavy = heavy)
            }
            freezingDrizzle, freezingRain -> {
                cloud(canvas, 50f, 40f, 0.95f, CLOUD, fill)
                stroke.color = ICE; stroke.strokeWidth = 6f
                canvas.drawLine(34f, 66f, 29f, 80f, stroke)
                canvas.drawLine(66f, 66f, 61f, 80f, stroke)
                flake(canvas, 49f, 78f, 7f, ICE, stroke)
            }
            snow, snowGrains, snowShowers -> {
                if (condition == snowShowers && isDay) sun(canvas, 70f, 26f, 12f, fill, stroke)
                cloud(canvas, 50f, 40f, 0.95f, CLOUD, fill)
                if (condition == snowGrains) {
                    fill.color = SNOW
                    for ((x, y) in listOf(32f to 70f, 50f to 76f, 68f to 70f, 41f to 88f, 59f to 88f)) canvas.drawCircle(x, y, 4f, fill)
                } else {
                    flake(canvas, 32f, 72f, 8f, SNOW, stroke)
                    flake(canvas, 66f, 72f, 8f, SNOW, stroke)
                    flake(canvas, 49f, 86f, 8f, SNOW, stroke)
                }
            }
            thunderstorm, thunderstormHail -> {
                cloud(canvas, 50f, 38f, 0.95f, CLOUD, fill)
                fill.color = BOLT
                val bolt = Path().apply {
                    moveTo(54f, 54f); lineTo(38f, 76f); lineTo(50f, 76f); lineTo(44f, 96f)
                    lineTo(64f, 70f); lineTo(52f, 70f); lineTo(60f, 54f); close()
                }
                canvas.drawPath(bolt, fill)
                if (condition == thunderstormHail) {
                    fill.color = SNOW
                    canvas.drawCircle(26f, 76f, 4.5f, fill); canvas.drawCircle(74f, 76f, 4.5f, fill)
                    canvas.drawCircle(30f, 90f, 4.5f, fill); canvas.drawCircle(70f, 90f, 4.5f, fill)
                } else {
                    stroke.color = RAIN; stroke.strokeWidth = 6f
                    canvas.drawLine(28f, 66f, 23f, 80f, stroke); canvas.drawLine(76f, 66f, 71f, 80f, stroke)
                }
            }
        }
        canvas.restore()
    }

    private fun sun(c: Canvas, x: Float, y: Float, r: Float, fill: Paint, stroke: Paint) {
        fill.color = SUN
        c.drawCircle(x, y, r, fill)
        stroke.color = SUN; stroke.strokeWidth = r * 0.28f
        for (i in 0 until 8) {
            val a = Math.PI * i / 4
            val r1 = r * 1.4f; val r2 = r * 1.85f
            c.drawLine(x + (cos(a) * r1).toFloat(), y + (sin(a) * r1).toFloat(),
                x + (cos(a) * r2).toFloat(), y + (sin(a) * r2).toFloat(), stroke)
        }
    }

    private fun moon(c: Canvas, x: Float, y: Float, r: Float, fill: Paint) {
        fill.color = MOON
        val outer = Path().apply { addCircle(x, y, r, Path.Direction.CW) }
        val bite = Path().apply { addCircle(x + r * 0.55f, y - r * 0.35f, r * 0.85f, Path.Direction.CW) }
        outer.op(bite, Path.Op.DIFFERENCE)
        c.drawPath(outer, fill)
    }

    /** A cloud centred at (x, y); scale 1 is about 64 units wide. */
    private fun cloud(c: Canvas, x: Float, y: Float, s: Float, color: Int, fill: Paint) {
        fill.color = color
        val p = Path()
        p.addRoundRect(RectF(x - 32f * s, y - 4f * s, x + 32f * s, y + 16f * s), 10f * s, 10f * s, Path.Direction.CW)
        p.addCircle(x - 13f * s, y, 13f * s, Path.Direction.CW)
        p.addCircle(x + 6f * s, y - 7f * s, 18f * s, Path.Direction.CW)
        p.addCircle(x + 22f * s, y + 3f * s, 11f * s, Path.Direction.CW)
        c.drawPath(p, fill)
    }

    private fun drops(c: Canvas, color: Int, short: Boolean, stroke: Paint, heavy: Boolean = false) {
        stroke.color = color; stroke.strokeWidth = when {
            short -> 7.5f
            heavy -> 9.5f
            else -> 8.5f
        }
        if (heavy) {
            for (x in listOf(28f, 50f, 72f)) c.drawLine(x, 58f, x - 6f, 75f, stroke)
            for (x in listOf(24f, 46f, 68f)) c.drawLine(x, 81f, x - 5f, 95f, stroke)
            return
        }
        val len = if (short) 13f else 18f
        for (x in listOf(32f, 50f, 68f)) c.drawLine(x, 62f, x - len * 0.35f, 62f + len, stroke)
        if (!short) for (x in listOf(41f, 59f)) c.drawLine(x, 84f, x - 3.5f, 94f, stroke)
    }

    private fun flake(c: Canvas, x: Float, y: Float, r: Float, color: Int, stroke: Paint) {
        stroke.color = color; stroke.strokeWidth = 3.2f
        for (i in 0 until 3) {
            val a = Math.PI * i / 3 + Math.PI / 2
            c.drawLine(x - (cos(a) * r).toFloat(), y - (sin(a) * r).toFloat(),
                x + (cos(a) * r).toFloat(), y + (sin(a) * r).toFloat(), stroke)
        }
    }
}

// Preserve scalar float interpolation; only the16-column Bayer phase varies
// along a vertical-gradient row. The caller supplies the original global y.
static void cpuFlatVerticalRow(const float color[4], const float to[4],
                               float y, float h, int yy,
                               float out[16][3], float *rowAlpha)
{
    /* Original scalar expression, hoisted because it is column-independent. */
    float v = (yy + .5f - y) / fmaxf(h, .001f);
    float t = v;
    t = fmaxf(0, fminf(1, t));

    float alpha = color[3] * (1 - t) + to[3] * t;

    for (int column = 0; column < 16; column++) {
        /* Original dither expression with column substituted for xx. */
        float dither = ((float)cpuFlatBayer[((unsigned)yy & 15) * 16 + ((unsigned)column & 15)] - 127.5f) / 65025.f;

        for (unsigned k = 0; k < 3; k++) {
            float premul = color[k] * color[3] * (1 - t) + to[k] * to[3] * t;
            out[column][k] = fmaxf(0, fminf(1, (alpha > 1e-6f ? premul / alpha : 0) + dither));
        }
    }

    *rowAlpha = alpha;
}

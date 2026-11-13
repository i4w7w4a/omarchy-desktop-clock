#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform ClockUniforms {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 glyphLayout; // padding, digit advance, colon advance, ink height
    vec2 glyphArea;
    vec4 changed;
    vec4 transition; // mode, progress, tail strength, fragment substitution
    vec4 slices;     // opacity, translation, half color spread, second pulse
    vec4 ink;
    vec4 contrast;   // ink opacity, contour thickness, contour opacity, shadow opacity
    float shadowOffset;
    vec4 highlight;  // cursor x, cursor y, radius, intensity
    vec4 shimmer;    // progress, strength, width, slope
};

layout(binding = 1) uniform sampler2D glyphs;
layout(binding = 2) uniform sampler2D shadows;

float glyphMask(sampler2D atlas, vec2 p, float row) {
    vec2 pos = clamp(p, vec2(0.5), glyphArea - vec2(0.5));
    float alpha = texture(atlas, vec2(pos.x / glyphArea.x, (pos.y / glyphArea.y + row) * 0.5)).a;
    return alpha * step(0.0, p.y) * step(p.y, glyphArea.y);
}

float changedCell(float x) {
    float relativeX = x - glyphLayout.x;
    float digit = glyphLayout.y;
    float colonRight = digit * 2.0 + glyphLayout.z;
    if (relativeX < digit) return changed.x;
    if (relativeX < digit * 2.0) return changed.y;
    if (relativeX < colonRight) return 0.0;
    return relativeX < colonRight + digit ? changed.z : changed.w;
}

float band(float y, float top, float bottom, float feather) {
    return smoothstep(top - feather, top + feather, y)
         * (1.0 - smoothstep(bottom - feather, bottom + feather, y));
}

float animatedMask(sampler2D atlas, vec2 p, float cellChanged) {
    if (cellChanged < 0.5 || transition.x < 0.5) return glyphMask(atlas, p, 0.0);

    float progress = transition.y;
    if (transition.x > 1.5) {
        float fade = 1.0 - pow(1.0 - progress, 3.0);
        return mix(glyphMask(atlas, p, 1.0), glyphMask(atlas, p, 0.0), fade);
    }

    // Both signs travel the same distance on a shared track, one ink height apart.
    float height = glyphLayout.w;
    float stepHeight = height * 1.035;
    float arriving = stepHeight * pow(1.0 - progress, 6.0);
    float leaving = stepHeight - arriving;
    float y = (p.y - glyphLayout.x) / height;
    float oldGate = 1.0 - smoothstep(0.96, 1.03, y);
    oldGate *= (1.0 - smoothstep(0.27, 0.42, progress));
    float newGate = smoothstep(-0.03, 0.04, y);
    float topGate = smoothstep(-0.10, 0.03, y);
    float bottomGate = 1.0 - smoothstep(0.97, 1.10, y);
    oldGate *= mix(1.0, topGate, smoothstep(0.0, 0.08, progress));
    newGate *= mix(bottomGate, 1.0, smoothstep(0.30, 0.42, progress));
    float outgoing = glyphMask(atlas, p + vec2(0.0, leaving), 1.0) * oldGate;
    float incoming = glyphMask(atlas, p - vec2(0.0, arriving), 0.0) * newGate;
    return incoming + outgoing * (1.0 - incoming);
}

float rollingShadow(vec2 p, float cellChanged) {
    float progress = transition.y;
    if (cellChanged < 0.5 || transition.x < 0.5 || transition.x > 1.5)
        return animatedMask(shadows, p, cellChanged);
    if (progress <= 0.0) return glyphMask(shadows, p, 1.0);
    if (progress >= 0.42)
        return glyphMask(shadows, p - vec2(0.0, glyphLayout.w * 1.035 * pow(1.0 - progress, 6.0)), 0.0);
    return animatedMask(shadows, p, cellChanged);
}

vec4 painted(vec3 color, float alpha) {
    return vec4(color * alpha, alpha);
}

vec4 over(vec4 foreground, vec4 background) {
    return foreground + background * (1.0 - foreground.a);
}

void main() {
    const vec3 dark = vec3(24.0, 32.0, 29.0) / 255.0;
    const vec3 cool = vec3(155.0, 215.0, 223.0) / 255.0;
    const vec3 warm = vec3(231.0, 157.0, 133.0) / 255.0;
    vec2 p = qt_TexCoord0 * glyphArea;
    float cellChanged = changedCell(p.x);
    float mask = animatedMask(glyphs, p, cellChanged);
    float radius = contrast.y;
    float outer = mask;
    if (radius > 0.0 && contrast.z > 0.0) {
        vec2 horizontal = vec2(radius, 0.0);
        vec2 vertical = horizontal.yx;
        vec2 diagonal = vec2(radius * 0.70710678);
        vec2 antiDiagonal = vec2(diagonal.x, -diagonal.y);
        outer = max(outer, animatedMask(glyphs, p + horizontal, cellChanged));
        outer = max(outer, animatedMask(glyphs, p - horizontal, cellChanged));
        outer = max(outer, animatedMask(glyphs, p + vertical, cellChanged));
        outer = max(outer, animatedMask(glyphs, p - vertical, cellChanged));
        outer = max(outer, animatedMask(glyphs, p + diagonal, cellChanged));
        outer = max(outer, animatedMask(glyphs, p - diagonal, cellChanged));
        outer = max(outer, animatedMask(glyphs, p + antiDiagonal, cellChanged));
        outer = max(outer, animatedMask(glyphs, p - antiDiagonal, cellChanged));
    }

    float light = transition.z * cellChanged;
    if (highlight.w > 0.0) {
        float falloff = 1.0 - smoothstep(0.0, highlight.z, distance(p, highlight.xy));
        light = mix(light, 1.0, falloff * highlight.w);
    }
    if (shimmer.y > 0.0) {
        float drift = glyphLayout.w * abs(shimmer.w) * 0.5 + shimmer.z;
        float center = mix(glyphLayout.x - drift, glyphArea.x - glyphLayout.x + drift, shimmer.x);
        float slopeX = p.x + (p.y - glyphArea.y * 0.5) * shimmer.w;
        float stripe = 1.0 - smoothstep(0.0, shimmer.z * 0.5, abs(slopeX - center));
        float envelope = sin(3.14159265 * clamp(shimmer.x, 0.0, 1.0));
        light = mix(light, 1.0, stripe * max(0.0, envelope) * shimmer.y);
    }

    vec4 result = vec4(0.0);
    if (contrast.w > 0.0) {
        float shadow = rollingShadow(p - vec2(0.0, shadowOffset), cellChanged);
        result = painted(dark, shadow * contrast.w);
    }
    result = over(painted(dark, (outer - mask) * contrast.z), result);
    result = over(painted(mix(ink.rgb, vec3(1.0), light), mask * contrast.x), result);

    if (slices.x > 0.0 && cellChanged > 0.5) {
        float y = (p.y - glyphLayout.x) / glyphLayout.w;
        float feather = 0.65 / glyphLayout.w;
        float upper = slices.w < 0.5 ? band(y, 0.19, 0.275, feather) : band(y, 0.32, 0.375, feather);
        float middle = slices.w < 0.5 ? band(y, 0.50, 0.57, feather) : 0.0;
        float lower = slices.w < 0.5 ? band(y, 0.72, 0.80, feather) : band(y, 0.63, 0.69, feather);
        float bandCoverage = max(upper, max(middle, lower));
        if (bandCoverage > 0.0) {
            float sign = middle > 0.0 || (slices.w > 0.5 && upper > 0.0) ? -1.0 : 1.0;
            vec2 shift = vec2(slices.y * sign, 0.0);
            vec2 spread = vec2(slices.z, 0.0);
            float sliceAlpha = bandCoverage * slices.x;
            float neutral = glyphMask(glyphs, p - shift, transition.w);
            result = over(painted(mix(ink.rgb, vec3(1.0), 0.18), neutral * sliceAlpha * 0.52), result);
            if (slices.z > 0.0) {
                float blue = glyphMask(glyphs, p - shift - spread, transition.w);
                float red = glyphMask(glyphs, p - shift + spread, transition.w);
                result = over(painted(cool, blue * sliceAlpha), result);
                result = over(painted(warm, red * sliceAlpha), result);
            }
        }
    }
    fragColor = result * qt_Opacity;
}

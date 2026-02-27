#ifndef DSL_SHADER_REGISTRY_H
#define DSL_SHADER_REGISTRY_H

typedef struct {
    float r;
    float g;
    float b;
    float a;
} dsl_color_t;

typedef struct {
    const char *name;
    const char *folder;
    void (*eval_pixel)(float time, float frame, float x, float y, float width, float height, float seed, dsl_color_t *out_color);
    int has_frame_func;
    void (*eval_frame)(float time, float frame);
} dsl_shader_entry_t;

extern const dsl_shader_entry_t dsl_shader_registry[];
extern const int dsl_shader_registry_count;

const dsl_shader_entry_t *dsl_shader_find(const char *name);
const dsl_shader_entry_t *dsl_shader_get(int index);

#endif /* DSL_SHADER_REGISTRY_H */

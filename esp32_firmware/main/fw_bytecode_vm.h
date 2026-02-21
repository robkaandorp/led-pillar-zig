#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define FW_BC3_VERSION 3U
#define FW_BC3_MAX_PARAMS 64U
#define FW_BC3_MAX_LAYERS 16U
#define FW_BC3_MAX_LET_SLOTS 128U
#define FW_BC3_MAX_EXPRESSIONS 512U
#define FW_BC3_MAX_STATEMENTS 512U
#define FW_BC3_MAX_EXPR_INSTRUCTIONS 256U
#define FW_BC3_MAX_EXPR_STACK 32U
#define FW_BC3_MAX_STATEMENT_DEPTH 16U
#define FW_BC3_MAX_LOOP_ITERATIONS 1024U
#define FW_BC3_DEFAULT_STATEMENT_BUDGET 8192U

typedef enum {
    FW_BC3_OK = 0,
    FW_BC3_ERR_INVALID_ARG,
    FW_BC3_ERR_BAD_MAGIC,
    FW_BC3_ERR_UNSUPPORTED_VERSION,
    FW_BC3_ERR_TRUNCATED,
    FW_BC3_ERR_FORMAT,
    FW_BC3_ERR_LIMIT,
    FW_BC3_ERR_INVALID_OPCODE,
    FW_BC3_ERR_INVALID_TAG,
    FW_BC3_ERR_INVALID_SLOT,
    FW_BC3_ERR_STACK_UNDERFLOW,
    FW_BC3_ERR_STACK_OVERFLOW,
    FW_BC3_ERR_TYPE_MISMATCH,
    FW_BC3_ERR_INVALID_BUILTIN,
    FW_BC3_ERR_LOOP_LIMIT,
    FW_BC3_ERR_EXEC_BUDGET,
} fw_bc3_status_t;

typedef enum {
    FW_BC3_VALUE_SCALAR = 1,
    FW_BC3_VALUE_VEC2 = 2,
    FW_BC3_VALUE_RGBA = 3,
} fw_bc3_value_tag_t;

typedef struct {
    float x;
    float y;
} fw_bc3_vec2_t;

typedef struct {
    float r;
    float g;
    float b;
    float a;
} fw_bc3_color_t;

typedef struct {
    fw_bc3_value_tag_t tag;
    union {
        float scalar;
        fw_bc3_vec2_t vec2;
        fw_bc3_color_t rgba;
    } as;
} fw_bc3_value_t;

typedef struct {
    uint32_t byte_offset;
    uint16_t instruction_count;
    uint16_t max_stack_depth;
} fw_bc3_expr_view_t;

typedef enum {
    FW_BC3_STMT_LET = 1,
    FW_BC3_STMT_BLEND = 2,
    FW_BC3_STMT_IF = 3,
    FW_BC3_STMT_FOR = 4,
} fw_bc3_stmt_kind_t;

typedef struct {
    fw_bc3_stmt_kind_t kind;
    union {
        struct {
            uint16_t slot;
            uint16_t expr_index;
        } let_decl;
        struct {
            uint16_t expr_index;
        } blend;
        struct {
            uint16_t cond_expr_index;
            uint16_t then_start;
            uint16_t then_count;
            uint16_t else_start;
            uint16_t else_count;
        } if_stmt;
        struct {
            uint16_t index_slot;
            uint32_t start_inclusive;
            uint32_t end_exclusive;
            uint16_t body_start;
            uint16_t body_count;
        } for_stmt;
    } as;
} fw_bc3_stmt_view_t;

typedef struct {
    const uint8_t *blob;
    size_t blob_len;
    uint16_t param_count;
    uint16_t layer_count;
    uint16_t frame_stmt_start;
    uint16_t frame_stmt_count;
    uint16_t frame_let_count;
    uint16_t layer_stmt_start[FW_BC3_MAX_LAYERS];
    uint16_t layer_stmt_count[FW_BC3_MAX_LAYERS];
    uint16_t layer_let_count[FW_BC3_MAX_LAYERS];
    uint8_t param_depends_xy[FW_BC3_MAX_PARAMS];
    uint16_t param_expr[FW_BC3_MAX_PARAMS];
    uint16_t expr_count;
    uint16_t stmt_count;
    fw_bc3_expr_view_t expressions[FW_BC3_MAX_EXPRESSIONS];
    fw_bc3_stmt_view_t statements[FW_BC3_MAX_STATEMENTS];
} fw_bc3_program_t;

typedef struct {
    const fw_bc3_program_t *program;
    float width;
    float height;
    float time_seconds;
    float frame_counter;
    bool has_dynamic_params;
    float param_values[FW_BC3_MAX_PARAMS];
    fw_bc3_value_t frame_values[FW_BC3_MAX_LET_SLOTS];
    fw_bc3_value_t let_values[FW_BC3_MAX_LET_SLOTS];
    fw_bc3_value_t expr_stack[FW_BC3_MAX_EXPR_STACK];
} fw_bc3_runtime_t;

fw_bc3_status_t fw_bc3_program_load(fw_bc3_program_t *program, const uint8_t *blob, size_t blob_len);
fw_bc3_status_t fw_bc3_runtime_init(fw_bc3_runtime_t *runtime, const fw_bc3_program_t *program, uint16_t width, uint16_t height);
fw_bc3_status_t fw_bc3_runtime_begin_frame(fw_bc3_runtime_t *runtime, float time_seconds, uint32_t frame_counter);
fw_bc3_status_t fw_bc3_runtime_eval_pixel(fw_bc3_runtime_t *runtime, float x, float y, fw_bc3_color_t *out_color);
const char *fw_bc3_status_to_string(fw_bc3_status_t status);

#include "fw_bytecode_vm.h"

#include <limits.h>
#include <math.h>
#include <string.h>

#define FW_BC3_INPUT_SLOT_COUNT 6U
#define FW_BC3_MAX_CALL_ARGS 8U
#define FW_BC3_BUILTIN_COUNT 20U

typedef enum {
    FW_BC3_OP_PUSH_LITERAL = 1,
    FW_BC3_OP_PUSH_SLOT = 2,
    FW_BC3_OP_NEGATE = 3,
    FW_BC3_OP_ADD = 4,
    FW_BC3_OP_SUB = 5,
    FW_BC3_OP_MUL = 6,
    FW_BC3_OP_DIV = 7,
    FW_BC3_OP_CALL_BUILTIN = 8,
} fw_bc3_expr_opcode_t;

typedef enum {
    FW_BC3_SLOT_INPUT = 1,
    FW_BC3_SLOT_PARAM = 2,
    FW_BC3_SLOT_FRAME_LET = 3,
    FW_BC3_SLOT_LET = 4,
} fw_bc3_slot_tag_t;

typedef enum {
    FW_BC3_INPUT_TIME = 0,
    FW_BC3_INPUT_FRAME = 1,
    FW_BC3_INPUT_X = 2,
    FW_BC3_INPUT_Y = 3,
    FW_BC3_INPUT_WIDTH = 4,
    FW_BC3_INPUT_HEIGHT = 5,
} fw_bc3_input_slot_t;

typedef enum {
    FW_BC3_BUILTIN_SIN = 0,
    FW_BC3_BUILTIN_COS = 1,
    FW_BC3_BUILTIN_SQRT = 2,
    FW_BC3_BUILTIN_LN = 3,
    FW_BC3_BUILTIN_LOG = 4,
    FW_BC3_BUILTIN_ABS = 5,
    FW_BC3_BUILTIN_FLOOR = 6,
    FW_BC3_BUILTIN_FRACT = 7,
    FW_BC3_BUILTIN_MIN = 8,
    FW_BC3_BUILTIN_MAX = 9,
    FW_BC3_BUILTIN_CLAMP = 10,
    FW_BC3_BUILTIN_SMOOTHSTEP = 11,
    FW_BC3_BUILTIN_CIRCLE = 12,
    FW_BC3_BUILTIN_BOX = 13,
    FW_BC3_BUILTIN_WRAPDX = 14,
    FW_BC3_BUILTIN_HASH01 = 15,
    FW_BC3_BUILTIN_HASH_SIGNED = 16,
    FW_BC3_BUILTIN_HASH_COORDS01 = 17,
    FW_BC3_BUILTIN_VEC2 = 18,
    FW_BC3_BUILTIN_RGBA = 19,
} fw_bc3_builtin_id_t;

typedef struct {
    const uint8_t *base;
    const uint8_t *cur;
    const uint8_t *end;
} fw_bc3_cursor_t;

typedef struct {
    uint8_t tag;
    uint32_t index;
} fw_bc3_slot_ref_t;

typedef struct {
    float time;
    float frame;
    float x;
    float y;
    float width;
    float height;
} fw_bc3_inputs_t;

typedef struct {
    uint16_t start;
    uint16_t count;
    uint16_t max_slot_plus_one;
} fw_bc3_stmt_block_info_t;

typedef enum {
    FW_BC3_PARAM_EVAL_ALL = 0,
    FW_BC3_PARAM_EVAL_STATIC_ONLY = 1,
    FW_BC3_PARAM_EVAL_DYNAMIC_ONLY = 2,
} fw_bc3_param_eval_mode_t;

static fw_bc3_value_t fw_bc3_make_scalar(float scalar) {
    fw_bc3_value_t value = {
        .tag = FW_BC3_VALUE_SCALAR,
        .as.scalar = scalar,
    };
    return value;
}

static fw_bc3_status_t fw_bc3_cursor_read_u8(fw_bc3_cursor_t *cursor, uint8_t *out) {
    if (cursor->cur >= cursor->end) {
        return FW_BC3_ERR_TRUNCATED;
    }
    *out = *cursor->cur;
    cursor->cur += 1;
    return FW_BC3_OK;
}

static fw_bc3_status_t fw_bc3_cursor_read_u16(fw_bc3_cursor_t *cursor, uint16_t *out) {
    if ((size_t)(cursor->end - cursor->cur) < 2U) {
        return FW_BC3_ERR_TRUNCATED;
    }
    // Host serializer writes all integer fields in little-endian order.
    *out = (uint16_t)cursor->cur[0] | ((uint16_t)cursor->cur[1] << 8U);
    cursor->cur += 2;
    return FW_BC3_OK;
}

static fw_bc3_status_t fw_bc3_cursor_read_u32(fw_bc3_cursor_t *cursor, uint32_t *out) {
    if ((size_t)(cursor->end - cursor->cur) < 4U) {
        return FW_BC3_ERR_TRUNCATED;
    }
    *out = (uint32_t)cursor->cur[0] | ((uint32_t)cursor->cur[1] << 8U) | ((uint32_t)cursor->cur[2] << 16U) |
           ((uint32_t)cursor->cur[3] << 24U);
    cursor->cur += 4;
    return FW_BC3_OK;
}

static fw_bc3_status_t fw_bc3_cursor_read_f32(fw_bc3_cursor_t *cursor, float *out) {
    uint32_t bits = 0;
    fw_bc3_status_t status = fw_bc3_cursor_read_u32(cursor, &bits);
    if (status != FW_BC3_OK) {
        return status;
    }
    memcpy(out, &bits, sizeof(bits));
    return FW_BC3_OK;
}

static fw_bc3_status_t fw_bc3_parse_runtime_value(fw_bc3_cursor_t *cursor, fw_bc3_value_t *out) {
    uint8_t tag = 0;
    fw_bc3_status_t status = fw_bc3_cursor_read_u8(cursor, &tag);
    if (status != FW_BC3_OK) {
        return status;
    }

    if (tag == FW_BC3_VALUE_SCALAR) {
        float scalar = 0.0f;
        status = fw_bc3_cursor_read_f32(cursor, &scalar);
        if (status != FW_BC3_OK) {
            return status;
        }
        if (out != NULL) {
            out->tag = FW_BC3_VALUE_SCALAR;
            out->as.scalar = scalar;
        }
        return FW_BC3_OK;
    }

    if (tag == FW_BC3_VALUE_VEC2) {
        float x = 0.0f;
        float y = 0.0f;
        status = fw_bc3_cursor_read_f32(cursor, &x);
        if (status != FW_BC3_OK) {
            return status;
        }
        status = fw_bc3_cursor_read_f32(cursor, &y);
        if (status != FW_BC3_OK) {
            return status;
        }
        if (out != NULL) {
            out->tag = FW_BC3_VALUE_VEC2;
            out->as.vec2 = (fw_bc3_vec2_t){
                .x = x,
                .y = y,
            };
        }
        return FW_BC3_OK;
    }

    if (tag == FW_BC3_VALUE_RGBA) {
        float r = 0.0f;
        float g = 0.0f;
        float b = 0.0f;
        float a = 0.0f;
        status = fw_bc3_cursor_read_f32(cursor, &r);
        if (status != FW_BC3_OK) {
            return status;
        }
        status = fw_bc3_cursor_read_f32(cursor, &g);
        if (status != FW_BC3_OK) {
            return status;
        }
        status = fw_bc3_cursor_read_f32(cursor, &b);
        if (status != FW_BC3_OK) {
            return status;
        }
        status = fw_bc3_cursor_read_f32(cursor, &a);
        if (status != FW_BC3_OK) {
            return status;
        }
        if (out != NULL) {
            out->tag = FW_BC3_VALUE_RGBA;
            out->as.rgba = (fw_bc3_color_t){
                .r = r,
                .g = g,
                .b = b,
                .a = a,
            };
        }
        return FW_BC3_OK;
    }

    return FW_BC3_ERR_INVALID_TAG;
}

static fw_bc3_status_t fw_bc3_parse_slot_ref(fw_bc3_cursor_t *cursor, fw_bc3_slot_ref_t *out) {
    uint8_t tag = 0;
    fw_bc3_status_t status = fw_bc3_cursor_read_u8(cursor, &tag);
    if (status != FW_BC3_OK) {
        return status;
    }

    out->tag = tag;
    if (tag == FW_BC3_SLOT_INPUT) {
        uint8_t input_slot = 0;
        status = fw_bc3_cursor_read_u8(cursor, &input_slot);
        if (status != FW_BC3_OK) {
            return status;
        }
        if (input_slot >= FW_BC3_INPUT_SLOT_COUNT) {
            return FW_BC3_ERR_INVALID_SLOT;
        }
        out->index = input_slot;
        return FW_BC3_OK;
    }

    if (tag == FW_BC3_SLOT_PARAM || tag == FW_BC3_SLOT_FRAME_LET || tag == FW_BC3_SLOT_LET) {
        uint32_t index = 0;
        status = fw_bc3_cursor_read_u32(cursor, &index);
        if (status != FW_BC3_OK) {
            return status;
        }
        out->index = index;
        return FW_BC3_OK;
    }

    return FW_BC3_ERR_INVALID_TAG;
}

static fw_bc3_status_t fw_bc3_parse_expression(fw_bc3_program_t *program, fw_bc3_cursor_t *cursor, uint16_t *out_expr_index) {
    uint32_t declared_max_stack = 0;
    uint32_t instruction_count = 0;
    fw_bc3_status_t status = fw_bc3_cursor_read_u32(cursor, &declared_max_stack);
    if (status != FW_BC3_OK) {
        return status;
    }
    status = fw_bc3_cursor_read_u32(cursor, &instruction_count);
    if (status != FW_BC3_OK) {
        return status;
    }

    if (declared_max_stack == 0U || declared_max_stack > FW_BC3_MAX_EXPR_STACK) {
        return FW_BC3_ERR_LIMIT;
    }
    if (instruction_count == 0U || instruction_count > FW_BC3_MAX_EXPR_INSTRUCTIONS) {
        return FW_BC3_ERR_LIMIT;
    }
    if (program->expr_count >= FW_BC3_MAX_EXPRESSIONS) {
        return FW_BC3_ERR_LIMIT;
    }

    const uint16_t expr_index = program->expr_count;
    program->expr_count += 1U;
    program->expressions[expr_index] = (fw_bc3_expr_view_t){
        .byte_offset = (uint32_t)(cursor->cur - cursor->base),
        .instruction_count = (uint16_t)instruction_count,
        .max_stack_depth = (uint16_t)declared_max_stack,
    };

    int32_t stack_depth = 0;
    uint32_t max_seen = 0;
    uint32_t i = 0;
    while (i < instruction_count) {
        uint8_t opcode = 0;
        status = fw_bc3_cursor_read_u8(cursor, &opcode);
        if (status != FW_BC3_OK) {
            return status;
        }

        if (opcode == FW_BC3_OP_PUSH_LITERAL) {
            status = fw_bc3_parse_runtime_value(cursor, NULL);
            if (status != FW_BC3_OK) {
                return status;
            }
            stack_depth += 1;
        } else if (opcode == FW_BC3_OP_PUSH_SLOT) {
            fw_bc3_slot_ref_t slot = {0};
            status = fw_bc3_parse_slot_ref(cursor, &slot);
            if (status != FW_BC3_OK) {
                return status;
            }
            if (slot.tag == FW_BC3_SLOT_PARAM && slot.index >= program->param_count) {
                return FW_BC3_ERR_INVALID_SLOT;
            }
            if ((slot.tag == FW_BC3_SLOT_FRAME_LET || slot.tag == FW_BC3_SLOT_LET) && slot.index >= FW_BC3_MAX_LET_SLOTS) {
                return FW_BC3_ERR_INVALID_SLOT;
            }
            stack_depth += 1;
        } else if (opcode == FW_BC3_OP_NEGATE) {
            if (stack_depth < 1) {
                return FW_BC3_ERR_STACK_UNDERFLOW;
            }
        } else if (opcode == FW_BC3_OP_ADD || opcode == FW_BC3_OP_SUB || opcode == FW_BC3_OP_MUL || opcode == FW_BC3_OP_DIV) {
            if (stack_depth < 2) {
                return FW_BC3_ERR_STACK_UNDERFLOW;
            }
            stack_depth -= 1;
        } else if (opcode == FW_BC3_OP_CALL_BUILTIN) {
            uint8_t builtin = 0;
            uint8_t arg_count = 0;
            status = fw_bc3_cursor_read_u8(cursor, &builtin);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_cursor_read_u8(cursor, &arg_count);
            if (status != FW_BC3_OK) {
                return status;
            }
            if (builtin >= FW_BC3_BUILTIN_COUNT) {
                return FW_BC3_ERR_INVALID_BUILTIN;
            }
            if (arg_count == 0U || arg_count > FW_BC3_MAX_CALL_ARGS) {
                return FW_BC3_ERR_FORMAT;
            }
            if (stack_depth < (int32_t)arg_count) {
                return FW_BC3_ERR_STACK_UNDERFLOW;
            }
            stack_depth = stack_depth - (int32_t)arg_count + 1;
        } else {
            return FW_BC3_ERR_INVALID_OPCODE;
        }

        if (stack_depth < 0) {
            return FW_BC3_ERR_STACK_UNDERFLOW;
        }
        if ((uint32_t)stack_depth > declared_max_stack || (uint32_t)stack_depth > FW_BC3_MAX_EXPR_STACK) {
            return FW_BC3_ERR_STACK_OVERFLOW;
        }
        if ((uint32_t)stack_depth > max_seen) {
            max_seen = (uint32_t)stack_depth;
        }
        i += 1U;
    }

    if (stack_depth != 1) {
        return FW_BC3_ERR_FORMAT;
    }
    if (max_seen > declared_max_stack) {
        return FW_BC3_ERR_FORMAT;
    }

    *out_expr_index = expr_index;
    return FW_BC3_OK;
}

static uint16_t fw_bc3_max_u16(uint16_t a, uint16_t b) {
    return (a > b) ? a : b;
}

static fw_bc3_status_t fw_bc3_parse_statement_block(
    fw_bc3_program_t *program,
    fw_bc3_cursor_t *cursor,
    uint8_t depth,
    fw_bc3_stmt_block_info_t *out
) {
    if (depth > FW_BC3_MAX_STATEMENT_DEPTH) {
        return FW_BC3_ERR_LIMIT;
    }

    // Each statement block is length-prefixed, then recursively nests child blocks for if/for.
    uint32_t statement_count = 0;
    fw_bc3_status_t status = fw_bc3_cursor_read_u32(cursor, &statement_count);
    if (status != FW_BC3_OK) {
        return status;
    }
    if (statement_count > UINT16_MAX) {
        return FW_BC3_ERR_LIMIT;
    }
    if (program->stmt_count + statement_count > FW_BC3_MAX_STATEMENTS) {
        return FW_BC3_ERR_LIMIT;
    }

    out->start = program->stmt_count;
    out->count = (uint16_t)statement_count;
    out->max_slot_plus_one = 0;

    uint32_t i = 0;
    while (i < statement_count) {
        uint16_t stmt_index = program->stmt_count;
        program->stmt_count += 1U;

        fw_bc3_stmt_view_t *stmt = &program->statements[stmt_index];
        uint8_t opcode = 0;
        status = fw_bc3_cursor_read_u8(cursor, &opcode);
        if (status != FW_BC3_OK) {
            return status;
        }

        if (opcode == FW_BC3_STMT_LET) {
            uint32_t slot = 0;
            uint16_t expr_index = 0;
            status = fw_bc3_cursor_read_u32(cursor, &slot);
            if (status != FW_BC3_OK) {
                return status;
            }
            if (slot >= FW_BC3_MAX_LET_SLOTS) {
                return FW_BC3_ERR_INVALID_SLOT;
            }
            status = fw_bc3_parse_expression(program, cursor, &expr_index);
            if (status != FW_BC3_OK) {
                return status;
            }

            stmt->kind = FW_BC3_STMT_LET;
            stmt->as.let_decl.slot = (uint16_t)slot;
            stmt->as.let_decl.expr_index = expr_index;
            out->max_slot_plus_one = fw_bc3_max_u16(out->max_slot_plus_one, (uint16_t)(slot + 1U));
        } else if (opcode == FW_BC3_STMT_BLEND) {
            uint16_t expr_index = 0;
            status = fw_bc3_parse_expression(program, cursor, &expr_index);
            if (status != FW_BC3_OK) {
                return status;
            }

            stmt->kind = FW_BC3_STMT_BLEND;
            stmt->as.blend.expr_index = expr_index;
        } else if (opcode == FW_BC3_STMT_IF) {
            uint16_t cond_expr = 0;
            fw_bc3_stmt_block_info_t then_block = {0};
            fw_bc3_stmt_block_info_t else_block = {0};

            status = fw_bc3_parse_expression(program, cursor, &cond_expr);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_parse_statement_block(program, cursor, (uint8_t)(depth + 1U), &then_block);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_parse_statement_block(program, cursor, (uint8_t)(depth + 1U), &else_block);
            if (status != FW_BC3_OK) {
                return status;
            }

            stmt->kind = FW_BC3_STMT_IF;
            stmt->as.if_stmt.cond_expr_index = cond_expr;
            stmt->as.if_stmt.then_start = then_block.start;
            stmt->as.if_stmt.then_count = then_block.count;
            stmt->as.if_stmt.else_start = else_block.start;
            stmt->as.if_stmt.else_count = else_block.count;

            out->max_slot_plus_one = fw_bc3_max_u16(out->max_slot_plus_one, then_block.max_slot_plus_one);
            out->max_slot_plus_one = fw_bc3_max_u16(out->max_slot_plus_one, else_block.max_slot_plus_one);
        } else if (opcode == FW_BC3_STMT_FOR) {
            uint32_t index_slot = 0;
            uint32_t start_inclusive = 0;
            uint32_t end_exclusive = 0;
            fw_bc3_stmt_block_info_t body_block = {0};

            status = fw_bc3_cursor_read_u32(cursor, &index_slot);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_cursor_read_u32(cursor, &start_inclusive);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_cursor_read_u32(cursor, &end_exclusive);
            if (status != FW_BC3_OK) {
                return status;
            }
            if (index_slot >= FW_BC3_MAX_LET_SLOTS) {
                return FW_BC3_ERR_INVALID_SLOT;
            }
            if (end_exclusive < start_inclusive) {
                return FW_BC3_ERR_FORMAT;
            }

            status = fw_bc3_parse_statement_block(program, cursor, (uint8_t)(depth + 1U), &body_block);
            if (status != FW_BC3_OK) {
                return status;
            }

            stmt->kind = FW_BC3_STMT_FOR;
            stmt->as.for_stmt.index_slot = (uint16_t)index_slot;
            stmt->as.for_stmt.start_inclusive = start_inclusive;
            stmt->as.for_stmt.end_exclusive = end_exclusive;
            stmt->as.for_stmt.body_start = body_block.start;
            stmt->as.for_stmt.body_count = body_block.count;

            out->max_slot_plus_one = fw_bc3_max_u16(out->max_slot_plus_one, (uint16_t)(index_slot + 1U));
            out->max_slot_plus_one = fw_bc3_max_u16(out->max_slot_plus_one, body_block.max_slot_plus_one);
        } else {
            return FW_BC3_ERR_INVALID_OPCODE;
        }

        i += 1U;
    }

    return FW_BC3_OK;
}

fw_bc3_status_t fw_bc3_program_load(fw_bc3_program_t *program, const uint8_t *blob, size_t blob_len) {
    if (program == NULL || blob == NULL || blob_len < 8U) {
        return FW_BC3_ERR_INVALID_ARG;
    }

    memset(program, 0, sizeof(*program));
    program->blob = blob;
    program->blob_len = blob_len;

    fw_bc3_cursor_t cursor = {
        .base = blob,
        .cur = blob,
        .end = blob + blob_len,
    };

    if ((size_t)(cursor.end - cursor.cur) < 4U || memcmp(cursor.cur, "DSLB", 4U) != 0) {
        return FW_BC3_ERR_BAD_MAGIC;
    }
    cursor.cur += 4U;

    uint16_t version = 0;
    fw_bc3_status_t status = fw_bc3_cursor_read_u16(&cursor, &version);
    if (status != FW_BC3_OK) {
        return status;
    }
    if (version != FW_BC3_VERSION) {
        return FW_BC3_ERR_UNSUPPORTED_VERSION;
    }

    // v3 keeps the reserved u16 directly after version for forward-compatible flags.
    uint16_t reserved_flags = 0;
    status = fw_bc3_cursor_read_u16(&cursor, &reserved_flags);
    if (status != FW_BC3_OK) {
        return status;
    }
    (void)reserved_flags;

    uint32_t param_count = 0;
    status = fw_bc3_cursor_read_u32(&cursor, &param_count);
    if (status != FW_BC3_OK) {
        return status;
    }
    if (param_count > FW_BC3_MAX_PARAMS) {
        return FW_BC3_ERR_LIMIT;
    }
    program->param_count = (uint16_t)param_count;

    uint32_t param_index = 0;
    while (param_index < param_count) {
        uint8_t depends_on_xy = 0;
        uint16_t expr_index = 0;
        status = fw_bc3_cursor_read_u8(&cursor, &depends_on_xy);
        if (status != FW_BC3_OK) {
            return status;
        }
        if (depends_on_xy > 1U) {
            return FW_BC3_ERR_FORMAT;
        }
        program->param_depends_xy[param_index] = depends_on_xy;

        status = fw_bc3_parse_expression(program, &cursor, &expr_index);
        if (status != FW_BC3_OK) {
            return status;
        }
        program->param_expr[param_index] = expr_index;
        param_index += 1U;
    }

    fw_bc3_stmt_block_info_t frame_block = {0};
    status = fw_bc3_parse_statement_block(program, &cursor, 0, &frame_block);
    if (status != FW_BC3_OK) {
        return status;
    }
    program->frame_stmt_start = frame_block.start;
    program->frame_stmt_count = frame_block.count;
    program->frame_let_count = frame_block.max_slot_plus_one;

    uint32_t layer_count = 0;
    status = fw_bc3_cursor_read_u32(&cursor, &layer_count);
    if (status != FW_BC3_OK) {
        return status;
    }
    if (layer_count > FW_BC3_MAX_LAYERS) {
        return FW_BC3_ERR_LIMIT;
    }
    program->layer_count = (uint16_t)layer_count;

    uint32_t layer_index = 0;
    while (layer_index < layer_count) {
        fw_bc3_stmt_block_info_t layer_block = {0};
        status = fw_bc3_parse_statement_block(program, &cursor, 0, &layer_block);
        if (status != FW_BC3_OK) {
            return status;
        }
        program->layer_stmt_start[layer_index] = layer_block.start;
        program->layer_stmt_count[layer_index] = layer_block.count;
        program->layer_let_count[layer_index] = layer_block.max_slot_plus_one;
        layer_index += 1U;
    }

    if (cursor.cur != cursor.end) {
        return FW_BC3_ERR_FORMAT;
    }

    return FW_BC3_OK;
}

static float fw_bc3_clamp01(float value) {
    if (value < 0.0f) {
        return 0.0f;
    }
    if (value > 1.0f) {
        return 1.0f;
    }
    return value;
}

static float fw_bc3_linearstep(float edge0, float edge1, float x) {
    if (edge0 == edge1) {
        return (x < edge0) ? 0.0f : 1.0f;
    }
    return fw_bc3_clamp01((x - edge0) / (edge1 - edge0));
}

static float fw_bc3_smoothstep(float edge0, float edge1, float x) {
    const float t = fw_bc3_linearstep(edge0, edge1, x);
    return t * t * (3.0f - (2.0f * t));
}

static uint32_t fw_bc3_hash_u32(uint32_t value) {
    uint32_t x = value;
    x ^= x >> 16U;
    x *= 0x7feb352dU;
    x ^= x >> 15U;
    x *= 0x846ca68bU;
    x ^= x >> 16U;
    return x;
}

static uint32_t fw_bc3_bitcast_u32_from_i32(int32_t value) {
    uint32_t out = 0;
    memcpy(&out, &value, sizeof(out));
    return out;
}

static int32_t fw_bc3_scalar_to_i32(float value) {
    const float min_i32 = (float)INT32_MIN;
    const float max_i32 = (float)INT32_MAX;
    if (value < min_i32) {
        value = min_i32;
    }
    if (value > max_i32) {
        value = max_i32;
    }
    return (int32_t)value;
}

static uint32_t fw_bc3_scalar_to_u32(float value) {
    return fw_bc3_bitcast_u32_from_i32(fw_bc3_scalar_to_i32(value));
}

static float fw_bc3_hash01(uint32_t value) {
    const uint32_t hashed = fw_bc3_hash_u32(value) & 0x00ffffffU;
    return (float)hashed / 16777215.0f;
}

static float fw_bc3_hash_signed(uint32_t value) {
    return (fw_bc3_hash01(value) * 2.0f) - 1.0f;
}

static float fw_bc3_hash_coords01(int32_t x, int32_t y, uint32_t seed) {
    const uint32_t ux = fw_bc3_bitcast_u32_from_i32(x);
    const uint32_t uy = fw_bc3_bitcast_u32_from_i32(y);
    const uint32_t mixed = (ux * 0x1f123bb5U) ^ (uy * 0x5f356495U) ^ seed;
    return fw_bc3_hash01(mixed);
}

static float fw_bc3_vec2_length(fw_bc3_vec2_t vec) {
    return sqrtf((vec.x * vec.x) + (vec.y * vec.y));
}

static float fw_bc3_wrapped_delta_x(float px, float center_x, float width) {
    float dx = px - center_x;
    const float half_width = width * 0.5f;
    if (dx > half_width) {
        dx -= width;
    }
    if (dx < -half_width) {
        dx += width;
    }
    return dx;
}

static fw_bc3_color_t fw_bc3_color_clamped(fw_bc3_color_t color) {
    fw_bc3_color_t out = color;
    out.r = fw_bc3_clamp01(out.r);
    out.g = fw_bc3_clamp01(out.g);
    out.b = fw_bc3_clamp01(out.b);
    out.a = fw_bc3_clamp01(out.a);
    return out;
}

static fw_bc3_color_t fw_bc3_blend_over(fw_bc3_color_t src, fw_bc3_color_t dst) {
    const fw_bc3_color_t s = fw_bc3_color_clamped(src);
    const fw_bc3_color_t d = fw_bc3_color_clamped(dst);
    const float out_a = s.a + (d.a * (1.0f - s.a));
    if (out_a <= 0.000001f) {
        return (fw_bc3_color_t){
            .r = 0.0f,
            .g = 0.0f,
            .b = 0.0f,
            .a = 0.0f,
        };
    }

    return (fw_bc3_color_t){
        .r = ((s.r * s.a) + (d.r * d.a * (1.0f - s.a))) / out_a,
        .g = ((s.g * s.a) + (d.g * d.a * (1.0f - s.a))) / out_a,
        .b = ((s.b * s.a) + (d.b * d.a * (1.0f - s.a))) / out_a,
        .a = out_a,
    };
}

static fw_bc3_status_t fw_bc3_value_as_scalar(const fw_bc3_value_t *value, float *out) {
    if (value->tag != FW_BC3_VALUE_SCALAR) {
        return FW_BC3_ERR_TYPE_MISMATCH;
    }
    *out = value->as.scalar;
    return FW_BC3_OK;
}

static fw_bc3_status_t fw_bc3_value_as_vec2(const fw_bc3_value_t *value, fw_bc3_vec2_t *out) {
    if (value->tag != FW_BC3_VALUE_VEC2) {
        return FW_BC3_ERR_TYPE_MISMATCH;
    }
    *out = value->as.vec2;
    return FW_BC3_OK;
}

static fw_bc3_status_t fw_bc3_eval_builtin(
    uint8_t builtin,
    const fw_bc3_value_t *args,
    uint8_t arg_count,
    fw_bc3_value_t *out
) {
    if (builtin >= FW_BC3_BUILTIN_COUNT) {
        return FW_BC3_ERR_INVALID_BUILTIN;
    }

    float a0 = 0.0f;
    float a1 = 0.0f;
    float a2 = 0.0f;
    fw_bc3_vec2_t v0 = {0};
    fw_bc3_vec2_t v1 = {0};
    fw_bc3_status_t status = FW_BC3_OK;

    switch ((fw_bc3_builtin_id_t)builtin) {
        case FW_BC3_BUILTIN_SIN:
            if (arg_count != 1U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar(sinf(a0));
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_COS:
            if (arg_count != 1U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar(cosf(a0));
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_SQRT:
            if (arg_count != 1U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar(sqrtf(a0));
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_LN:
            if (arg_count != 1U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar(logf(a0));
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_LOG:
            if (arg_count != 1U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar(log10f(a0));
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_ABS:
            if (arg_count != 1U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar(fabsf(a0));
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_FLOOR:
            if (arg_count != 1U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar(floorf(a0));
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_FRACT:
            if (arg_count != 1U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar(a0 - floorf(a0));
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_MIN:
            if (arg_count != 2U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_scalar(&args[1], &a1);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar((a0 < a1) ? a0 : a1);
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_MAX:
            if (arg_count != 2U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_scalar(&args[1], &a1);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar((a0 > a1) ? a0 : a1);
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_CLAMP:
            if (arg_count != 3U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_scalar(&args[1], &a1);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_scalar(&args[2], &a2);
            if (status != FW_BC3_OK) {
                return status;
            }
            if (a0 < a1) {
                *out = fw_bc3_make_scalar(a1);
            } else if (a0 > a2) {
                *out = fw_bc3_make_scalar(a2);
            } else {
                *out = fw_bc3_make_scalar(a0);
            }
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_SMOOTHSTEP:
            if (arg_count != 3U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_scalar(&args[1], &a1);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_scalar(&args[2], &a2);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar(fw_bc3_smoothstep(a0, a1, a2));
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_CIRCLE:
            if (arg_count != 2U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_vec2(&args[0], &v0);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_scalar(&args[1], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar(fw_bc3_vec2_length(v0) - a0);
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_BOX: {
            fw_bc3_vec2_t q = {0};
            fw_bc3_vec2_t outside = {0};
            float inside = 0.0f;

            if (arg_count != 2U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_vec2(&args[0], &v0);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_vec2(&args[1], &v1);
            if (status != FW_BC3_OK) {
                return status;
            }

            q.x = fabsf(v0.x) - v1.x;
            q.y = fabsf(v0.y) - v1.y;
            outside.x = (q.x > 0.0f) ? q.x : 0.0f;
            outside.y = (q.y > 0.0f) ? q.y : 0.0f;
            inside = fminf(fmaxf(q.x, q.y), 0.0f);
            *out = fw_bc3_make_scalar(fw_bc3_vec2_length(outside) + inside);
            return FW_BC3_OK;
        }
        case FW_BC3_BUILTIN_WRAPDX:
            if (arg_count != 3U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_scalar(&args[1], &a1);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_scalar(&args[2], &a2);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar(fw_bc3_wrapped_delta_x(a0, a1, a2));
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_HASH01:
            if (arg_count != 1U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar(fw_bc3_hash01(fw_bc3_scalar_to_u32(a0)));
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_HASH_SIGNED:
            if (arg_count != 1U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar(fw_bc3_hash_signed(fw_bc3_scalar_to_u32(a0)));
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_HASH_COORDS01:
            if (arg_count != 3U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_scalar(&args[1], &a1);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_scalar(&args[2], &a2);
            if (status != FW_BC3_OK) {
                return status;
            }
            *out = fw_bc3_make_scalar(
                fw_bc3_hash_coords01(fw_bc3_scalar_to_i32(a0), fw_bc3_scalar_to_i32(a1), fw_bc3_scalar_to_u32(a2))
            );
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_VEC2:
            if (arg_count != 2U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_scalar(&args[1], &a1);
            if (status != FW_BC3_OK) {
                return status;
            }
            out->tag = FW_BC3_VALUE_VEC2;
            out->as.vec2.x = a0;
            out->as.vec2.y = a1;
            return FW_BC3_OK;
        case FW_BC3_BUILTIN_RGBA:
            if (arg_count != 4U) {
                return FW_BC3_ERR_FORMAT;
            }
            status = fw_bc3_value_as_scalar(&args[0], &a0);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_scalar(&args[1], &a1);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_scalar(&args[2], &a2);
            if (status != FW_BC3_OK) {
                return status;
            }
            {
                float a3 = 0.0f;
                status = fw_bc3_value_as_scalar(&args[3], &a3);
                if (status != FW_BC3_OK) {
                    return status;
                }
                out->tag = FW_BC3_VALUE_RGBA;
                out->as.rgba = (fw_bc3_color_t){
                    .r = a0,
                    .g = a1,
                    .b = a2,
                    .a = a3,
                };
            }
            return FW_BC3_OK;
        default:
            return FW_BC3_ERR_INVALID_BUILTIN;
    }
}

static void fw_bc3_reset_value_slots(fw_bc3_value_t *values, uint16_t count) {
    uint16_t i = 0;
    while (i < count) {
        values[i] = fw_bc3_make_scalar(0.0f);
        i += 1U;
    }
}

static fw_bc3_status_t fw_bc3_load_slot(
    fw_bc3_runtime_t *runtime,
    const fw_bc3_inputs_t *inputs,
    const fw_bc3_slot_ref_t *slot,
    uint16_t let_limit,
    fw_bc3_value_t *out
) {
    if (slot->tag == FW_BC3_SLOT_INPUT) {
        switch ((fw_bc3_input_slot_t)slot->index) {
            case FW_BC3_INPUT_TIME:
                *out = fw_bc3_make_scalar(inputs->time);
                return FW_BC3_OK;
            case FW_BC3_INPUT_FRAME:
                *out = fw_bc3_make_scalar(inputs->frame);
                return FW_BC3_OK;
            case FW_BC3_INPUT_X:
                *out = fw_bc3_make_scalar(inputs->x);
                return FW_BC3_OK;
            case FW_BC3_INPUT_Y:
                *out = fw_bc3_make_scalar(inputs->y);
                return FW_BC3_OK;
            case FW_BC3_INPUT_WIDTH:
                *out = fw_bc3_make_scalar(inputs->width);
                return FW_BC3_OK;
            case FW_BC3_INPUT_HEIGHT:
                *out = fw_bc3_make_scalar(inputs->height);
                return FW_BC3_OK;
            default:
                return FW_BC3_ERR_INVALID_SLOT;
        }
    }

    if (slot->tag == FW_BC3_SLOT_PARAM) {
        if (slot->index >= runtime->program->param_count) {
            return FW_BC3_ERR_INVALID_SLOT;
        }
        *out = fw_bc3_make_scalar(runtime->param_values[slot->index]);
        return FW_BC3_OK;
    }

    if (slot->tag == FW_BC3_SLOT_FRAME_LET) {
        if (slot->index >= runtime->program->frame_let_count) {
            return FW_BC3_ERR_INVALID_SLOT;
        }
        *out = runtime->frame_values[slot->index];
        return FW_BC3_OK;
    }

    if (slot->tag == FW_BC3_SLOT_LET) {
        if (slot->index >= let_limit) {
            return FW_BC3_ERR_INVALID_SLOT;
        }
        *out = runtime->let_values[slot->index];
        return FW_BC3_OK;
    }

    return FW_BC3_ERR_INVALID_SLOT;
}

static fw_bc3_status_t fw_bc3_eval_expression(
    fw_bc3_runtime_t *runtime,
    uint16_t expr_index,
    const fw_bc3_inputs_t *inputs,
    uint16_t let_limit,
    fw_bc3_value_t *out
) {
    if (expr_index >= runtime->program->expr_count) {
        return FW_BC3_ERR_FORMAT;
    }

    const fw_bc3_expr_view_t *expr = &runtime->program->expressions[expr_index];
    if (expr->max_stack_depth > FW_BC3_MAX_EXPR_STACK) {
        return FW_BC3_ERR_LIMIT;
    }
    if ((size_t)expr->byte_offset >= runtime->program->blob_len) {
        return FW_BC3_ERR_TRUNCATED;
    }

    fw_bc3_cursor_t cursor = {
        .base = runtime->program->blob,
        .cur = runtime->program->blob + expr->byte_offset,
        .end = runtime->program->blob + runtime->program->blob_len,
    };

    uint16_t stack_len = 0;
    uint16_t i = 0;
    while (i < expr->instruction_count) {
        uint8_t opcode = 0;
        fw_bc3_status_t status = fw_bc3_cursor_read_u8(&cursor, &opcode);
        if (status != FW_BC3_OK) {
            return status;
        }

        if (opcode == FW_BC3_OP_PUSH_LITERAL) {
            fw_bc3_value_t value = {0};
            status = fw_bc3_parse_runtime_value(&cursor, &value);
            if (status != FW_BC3_OK) {
                return status;
            }
            if (stack_len >= FW_BC3_MAX_EXPR_STACK || stack_len >= expr->max_stack_depth) {
                return FW_BC3_ERR_STACK_OVERFLOW;
            }
            runtime->expr_stack[stack_len] = value;
            stack_len += 1U;
        } else if (opcode == FW_BC3_OP_PUSH_SLOT) {
            fw_bc3_slot_ref_t slot = {0};
            fw_bc3_value_t value = {0};
            status = fw_bc3_parse_slot_ref(&cursor, &slot);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_load_slot(runtime, inputs, &slot, let_limit, &value);
            if (status != FW_BC3_OK) {
                return status;
            }
            if (stack_len >= FW_BC3_MAX_EXPR_STACK || stack_len >= expr->max_stack_depth) {
                return FW_BC3_ERR_STACK_OVERFLOW;
            }
            runtime->expr_stack[stack_len] = value;
            stack_len += 1U;
        } else if (opcode == FW_BC3_OP_NEGATE) {
            float scalar = 0.0f;
            if (stack_len < 1U) {
                return FW_BC3_ERR_STACK_UNDERFLOW;
            }
            status = fw_bc3_value_as_scalar(&runtime->expr_stack[stack_len - 1U], &scalar);
            if (status != FW_BC3_OK) {
                return status;
            }
            runtime->expr_stack[stack_len - 1U] = fw_bc3_make_scalar(-scalar);
        } else if (
            opcode == FW_BC3_OP_ADD || opcode == FW_BC3_OP_SUB || opcode == FW_BC3_OP_MUL || opcode == FW_BC3_OP_DIV
        ) {
            float lhs = 0.0f;
            float rhs = 0.0f;
            if (stack_len < 2U) {
                return FW_BC3_ERR_STACK_UNDERFLOW;
            }
            status = fw_bc3_value_as_scalar(&runtime->expr_stack[stack_len - 2U], &lhs);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_value_as_scalar(&runtime->expr_stack[stack_len - 1U], &rhs);
            if (status != FW_BC3_OK) {
                return status;
            }
            stack_len -= 1U;
            if (opcode == FW_BC3_OP_ADD) {
                runtime->expr_stack[stack_len - 1U] = fw_bc3_make_scalar(lhs + rhs);
            } else if (opcode == FW_BC3_OP_SUB) {
                runtime->expr_stack[stack_len - 1U] = fw_bc3_make_scalar(lhs - rhs);
            } else if (opcode == FW_BC3_OP_MUL) {
                runtime->expr_stack[stack_len - 1U] = fw_bc3_make_scalar(lhs * rhs);
            } else {
                runtime->expr_stack[stack_len - 1U] = fw_bc3_make_scalar(lhs / rhs);
            }
        } else if (opcode == FW_BC3_OP_CALL_BUILTIN) {
            uint8_t builtin = 0;
            uint8_t arg_count = 0;
            fw_bc3_value_t result = {0};
            status = fw_bc3_cursor_read_u8(&cursor, &builtin);
            if (status != FW_BC3_OK) {
                return status;
            }
            status = fw_bc3_cursor_read_u8(&cursor, &arg_count);
            if (status != FW_BC3_OK) {
                return status;
            }
            if (arg_count == 0U || arg_count > FW_BC3_MAX_CALL_ARGS) {
                return FW_BC3_ERR_FORMAT;
            }
            if (stack_len < arg_count) {
                return FW_BC3_ERR_STACK_UNDERFLOW;
            }
            status = fw_bc3_eval_builtin(builtin, &runtime->expr_stack[stack_len - arg_count], arg_count, &result);
            if (status != FW_BC3_OK) {
                return status;
            }
            stack_len = (uint16_t)(stack_len - arg_count);
            runtime->expr_stack[stack_len] = result;
            stack_len += 1U;
        } else {
            return FW_BC3_ERR_INVALID_OPCODE;
        }

        i += 1U;
    }

    if (stack_len != 1U) {
        return FW_BC3_ERR_FORMAT;
    }
    *out = runtime->expr_stack[0];
    return FW_BC3_OK;
}

static fw_bc3_status_t fw_bc3_execute_statement_block(
    fw_bc3_runtime_t *runtime,
    uint16_t start,
    uint16_t count,
    bool frame_mode,
    uint16_t let_limit,
    const fw_bc3_inputs_t *inputs,
    fw_bc3_color_t *out_color,
    uint8_t depth,
    uint32_t *remaining_budget
) {
    if (depth > FW_BC3_MAX_STATEMENT_DEPTH) {
        return FW_BC3_ERR_LIMIT;
    }
    if ((uint32_t)start + (uint32_t)count > runtime->program->stmt_count) {
        return FW_BC3_ERR_FORMAT;
    }

    uint16_t i = 0;
    while (i < count) {
        fw_bc3_status_t status = FW_BC3_OK;
        const fw_bc3_stmt_view_t *stmt = &runtime->program->statements[start + i];
        if (*remaining_budget == 0U) {
            return FW_BC3_ERR_EXEC_BUDGET;
        }
        *remaining_budget -= 1U;

        switch (stmt->kind) {
            case FW_BC3_STMT_LET: {
                fw_bc3_value_t value = {0};
                if (stmt->as.let_decl.slot >= let_limit) {
                    return FW_BC3_ERR_INVALID_SLOT;
                }
                status = fw_bc3_eval_expression(
                    runtime,
                    stmt->as.let_decl.expr_index,
                    inputs,
                    let_limit,
                    &value
                );
                if (status != FW_BC3_OK) {
                    return status;
                }
                runtime->let_values[stmt->as.let_decl.slot] = value;
                if (frame_mode) {
                    runtime->frame_values[stmt->as.let_decl.slot] = value;
                }
                break;
            }
            case FW_BC3_STMT_BLEND: {
                fw_bc3_value_t value = {0};
                if (frame_mode) {
                    return FW_BC3_ERR_FORMAT;
                }
                status = fw_bc3_eval_expression(runtime, stmt->as.blend.expr_index, inputs, let_limit, &value);
                if (status != FW_BC3_OK) {
                    return status;
                }
                if (value.tag != FW_BC3_VALUE_RGBA) {
                    return FW_BC3_ERR_TYPE_MISMATCH;
                }
                *out_color = fw_bc3_blend_over(value.as.rgba, *out_color);
                break;
            }
            case FW_BC3_STMT_IF: {
                fw_bc3_value_t condition = {0};
                status = fw_bc3_eval_expression(runtime, stmt->as.if_stmt.cond_expr_index, inputs, let_limit, &condition);
                if (status != FW_BC3_OK) {
                    return status;
                }
                if (condition.tag != FW_BC3_VALUE_SCALAR) {
                    return FW_BC3_ERR_TYPE_MISMATCH;
                }
                if (condition.as.scalar > 0.0f) {
                    status = fw_bc3_execute_statement_block(
                        runtime,
                        stmt->as.if_stmt.then_start,
                        stmt->as.if_stmt.then_count,
                        frame_mode,
                        let_limit,
                        inputs,
                        out_color,
                        (uint8_t)(depth + 1U),
                        remaining_budget
                    );
                } else {
                    status = fw_bc3_execute_statement_block(
                        runtime,
                        stmt->as.if_stmt.else_start,
                        stmt->as.if_stmt.else_count,
                        frame_mode,
                        let_limit,
                        inputs,
                        out_color,
                        (uint8_t)(depth + 1U),
                        remaining_budget
                    );
                }
                if (status != FW_BC3_OK) {
                    return status;
                }
                break;
            }
            case FW_BC3_STMT_FOR: {
                const uint32_t start_value = stmt->as.for_stmt.start_inclusive;
                const uint32_t end_value = stmt->as.for_stmt.end_exclusive;
                uint32_t iter = 0;
                if (stmt->as.for_stmt.index_slot >= let_limit) {
                    return FW_BC3_ERR_INVALID_SLOT;
                }
                if (end_value < start_value) {
                    return FW_BC3_ERR_FORMAT;
                }
                if ((end_value - start_value) > FW_BC3_MAX_LOOP_ITERATIONS) {
                    return FW_BC3_ERR_LOOP_LIMIT;
                }
                iter = start_value;
                while (iter < end_value) {
                    const fw_bc3_value_t index_value = fw_bc3_make_scalar((float)iter);
                    runtime->let_values[stmt->as.for_stmt.index_slot] = index_value;
                    if (frame_mode) {
                        runtime->frame_values[stmt->as.for_stmt.index_slot] = index_value;
                    }
                    status = fw_bc3_execute_statement_block(
                        runtime,
                        stmt->as.for_stmt.body_start,
                        stmt->as.for_stmt.body_count,
                        frame_mode,
                        let_limit,
                        inputs,
                        out_color,
                        (uint8_t)(depth + 1U),
                        remaining_budget
                    );
                    if (status != FW_BC3_OK) {
                        return status;
                    }
                    iter += 1U;
                }
                break;
            }
            default:
                return FW_BC3_ERR_FORMAT;
        }

        i += 1U;
    }

    return FW_BC3_OK;
}

static fw_bc3_status_t fw_bc3_evaluate_params(
    fw_bc3_runtime_t *runtime,
    const fw_bc3_inputs_t *inputs,
    fw_bc3_param_eval_mode_t mode
) {
    uint16_t i = 0;
    while (i < runtime->program->param_count) {
        const bool is_dynamic = runtime->program->param_depends_xy[i] != 0U;
        fw_bc3_value_t value = {0};
        fw_bc3_status_t status = FW_BC3_OK;

        if (mode == FW_BC3_PARAM_EVAL_STATIC_ONLY && is_dynamic) {
            i += 1U;
            continue;
        }
        if (mode == FW_BC3_PARAM_EVAL_DYNAMIC_ONLY && !is_dynamic) {
            i += 1U;
            continue;
        }

        status = fw_bc3_eval_expression(runtime, runtime->program->param_expr[i], inputs, 0, &value);
        if (status != FW_BC3_OK) {
            return status;
        }
        if (value.tag != FW_BC3_VALUE_SCALAR) {
            return FW_BC3_ERR_TYPE_MISMATCH;
        }
        runtime->param_values[i] = value.as.scalar;
        i += 1U;
    }

    return FW_BC3_OK;
}

fw_bc3_status_t fw_bc3_runtime_init(fw_bc3_runtime_t *runtime, const fw_bc3_program_t *program, uint16_t width, uint16_t height) {
    if (runtime == NULL || program == NULL || width == 0U || height == 0U) {
        return FW_BC3_ERR_INVALID_ARG;
    }

    memset(runtime, 0, sizeof(*runtime));
    runtime->program = program;
    runtime->width = (float)width;
    runtime->height = (float)height;

    uint16_t i = 0;
    while (i < program->param_count) {
        if (program->param_depends_xy[i] != 0U) {
            runtime->has_dynamic_params = true;
            break;
        }
        i += 1U;
    }

    fw_bc3_reset_value_slots(runtime->frame_values, FW_BC3_MAX_LET_SLOTS);
    fw_bc3_reset_value_slots(runtime->let_values, FW_BC3_MAX_LET_SLOTS);

    return FW_BC3_OK;
}

fw_bc3_status_t fw_bc3_runtime_begin_frame(fw_bc3_runtime_t *runtime, float time_seconds, uint32_t frame_counter) {
    if (runtime == NULL || runtime->program == NULL) {
        return FW_BC3_ERR_INVALID_ARG;
    }

    runtime->time_seconds = time_seconds;
    runtime->frame_counter = (float)frame_counter;
    fw_bc3_reset_value_slots(runtime->frame_values, FW_BC3_MAX_LET_SLOTS);
    fw_bc3_reset_value_slots(runtime->let_values, FW_BC3_MAX_LET_SLOTS);

    fw_bc3_inputs_t inputs = {
        .time = runtime->time_seconds,
        .frame = runtime->frame_counter,
        .x = 0.0f,
        .y = 0.0f,
        .width = runtime->width,
        .height = runtime->height,
    };

    fw_bc3_status_t status = fw_bc3_evaluate_params(runtime, &inputs, FW_BC3_PARAM_EVAL_STATIC_ONLY);
    if (status != FW_BC3_OK) {
        return status;
    }

    uint32_t budget = FW_BC3_DEFAULT_STATEMENT_BUDGET;
    fw_bc3_color_t dummy = {
        .r = 0.0f,
        .g = 0.0f,
        .b = 0.0f,
        .a = 1.0f,
    };
    return fw_bc3_execute_statement_block(
        runtime,
        runtime->program->frame_stmt_start,
        runtime->program->frame_stmt_count,
        true,
        runtime->program->frame_let_count,
        &inputs,
        &dummy,
        0,
        &budget
    );
}

fw_bc3_status_t fw_bc3_runtime_eval_pixel(fw_bc3_runtime_t *runtime, float x, float y, fw_bc3_color_t *out_color) {
    if (runtime == NULL || runtime->program == NULL || out_color == NULL) {
        return FW_BC3_ERR_INVALID_ARG;
    }

    fw_bc3_inputs_t inputs = {
        .time = runtime->time_seconds,
        .frame = runtime->frame_counter,
        .x = x,
        .y = y,
        .width = runtime->width,
        .height = runtime->height,
    };

    if (runtime->has_dynamic_params) {
        fw_bc3_status_t status = fw_bc3_evaluate_params(runtime, &inputs, FW_BC3_PARAM_EVAL_DYNAMIC_ONLY);
        if (status != FW_BC3_OK) {
            return status;
        }
    }

    fw_bc3_color_t out = {
        .r = 0.0f,
        .g = 0.0f,
        .b = 0.0f,
        .a = 1.0f,
    };
    uint32_t budget = FW_BC3_DEFAULT_STATEMENT_BUDGET;

    uint16_t layer = 0;
    while (layer < runtime->program->layer_count) {
        fw_bc3_status_t status = fw_bc3_execute_statement_block(
            runtime,
            runtime->program->layer_stmt_start[layer],
            runtime->program->layer_stmt_count[layer],
            false,
            runtime->program->layer_let_count[layer],
            &inputs,
            &out,
            0,
            &budget
        );
        if (status != FW_BC3_OK) {
            return status;
        }
        layer += 1U;
    }

    *out_color = out;
    return FW_BC3_OK;
}

const char *fw_bc3_status_to_string(fw_bc3_status_t status) {
    switch (status) {
        case FW_BC3_OK:
            return "ok";
        case FW_BC3_ERR_INVALID_ARG:
            return "invalid_arg";
        case FW_BC3_ERR_BAD_MAGIC:
            return "bad_magic";
        case FW_BC3_ERR_UNSUPPORTED_VERSION:
            return "unsupported_version";
        case FW_BC3_ERR_TRUNCATED:
            return "truncated";
        case FW_BC3_ERR_FORMAT:
            return "format";
        case FW_BC3_ERR_LIMIT:
            return "limit";
        case FW_BC3_ERR_INVALID_OPCODE:
            return "invalid_opcode";
        case FW_BC3_ERR_INVALID_TAG:
            return "invalid_tag";
        case FW_BC3_ERR_INVALID_SLOT:
            return "invalid_slot";
        case FW_BC3_ERR_STACK_UNDERFLOW:
            return "stack_underflow";
        case FW_BC3_ERR_STACK_OVERFLOW:
            return "stack_overflow";
        case FW_BC3_ERR_TYPE_MISMATCH:
            return "type_mismatch";
        case FW_BC3_ERR_INVALID_BUILTIN:
            return "invalid_builtin";
        case FW_BC3_ERR_LOOP_LIMIT:
            return "loop_limit";
        case FW_BC3_ERR_EXEC_BUDGET:
            return "exec_budget";
        default:
            return "unknown";
    }
}

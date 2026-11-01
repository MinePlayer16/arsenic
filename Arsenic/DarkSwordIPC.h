#ifndef DarkSwordIPC_h //other related file are installer/DarkswordServer.m and installer/DarkSwordServer.h
#define DarkSwordIPC_h

#include <stdint.h>

#define DARK_SWORD_TCP_PORT 28282
#define DARK_SWORD_TCP_ADDR "127.0.0.1"

typedef enum {
    OP_PING = 0,
    OP_ISSUE_EXTENSION = 1,
} ds_ipc_op_t;

typedef struct {
    uint32_t op;
    uint32_t padding;
    uint64_t address;
    uint64_t value;
    uint32_t size;
    uint32_t padding2;
} ds_ipc_request_t;

typedef struct {
    uint32_t status;
    uint32_t padding;
    uint64_t data;
} ds_ipc_response_t;

#endif

#ifndef GIT_ENGINE_ODB_H
#define GIT_ENGINE_ODB_H

#include "erl_nif.h"
#include <git2.h>

ERL_NIF_TERM git_engine_odb_hash(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_odb_exists(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_odb_read(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_odb_write(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_odb_write_pack(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

ERL_NIF_TERM git_engine_odb_get_writepack(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_odb_writepack_append(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_odb_writepack_commit(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

void git_engine_odb_free(ErlNifEnv *env, void *cd);
void git_engine_odb_writepack_free(ErlNifEnv *env, void *cd);

extern ErlNifResourceType *git_engine_odb_type;
extern ErlNifResourceType *git_engine_odb_writepack_type;

typedef struct {
    git_odb *odb;
} git_engine_odb;

typedef struct {
    git_odb_writepack *odb_writepack;
} git_engine_odb_writepack;

#endif

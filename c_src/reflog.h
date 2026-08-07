#ifndef GIT_ENGINE_REFLOG_H
#define GIT_ENGINE_REFLOG_H

#include "erl_nif.h"
#include <git2.h>

ERL_NIF_TERM git_engine_reflog_count(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_reflog_read(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_reflog_delete(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif

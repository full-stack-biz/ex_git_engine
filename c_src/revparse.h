#ifndef GIT_ENGINE_REVPARSE_H
#define GIT_ENGINE_REVPARSE_H

#include "erl_nif.h"

ERL_NIF_TERM git_engine_revparse_single(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_revparse_ext(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif

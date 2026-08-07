#ifndef GIT_ENGINE_MERGE_H
#define GIT_ENGINE_MERGE_H

#include "erl_nif.h"

ERL_NIF_TERM git_engine_merge_commits(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_merge_base(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif

#ifndef GIT_ENGINE_BLAME_H
#define GIT_ENGINE_BLAME_H

#include "erl_nif.h"

ERL_NIF_TERM git_engine_blame_file(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif

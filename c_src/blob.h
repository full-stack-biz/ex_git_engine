#ifndef GIT_ENGINE_BLOB_H
#define GIT_ENGINE_BLOB_H

#include "object.h"

ERL_NIF_TERM git_engine_blob_size(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_blob_content(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif

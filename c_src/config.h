#ifndef GIT_ENGINE_CONFIG_H
#define GIT_ENGINE_CONFIG_H

#include "erl_nif.h"
#include <git2.h>

void git_engine_config_free(ErlNifEnv *env, void *cd);
ERL_NIF_TERM git_engine_config_set_bool(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_config_get_bool(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_config_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_config_set_string(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_config_get_string(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

extern ErlNifResourceType *git_engine_config_type;

typedef struct {
	git_config *config;
} git_engine_config;

#endif

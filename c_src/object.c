#include "ex_git_engine.h"
#include "repository.h"
#include "object.h"
#include "oid.h"
#include <zlib.h>
#include <string.h>
#include <git2.h>

void git_engine_object_free(ErlNifEnv *env, void *cd)
{
    git_engine_object *obj = (git_engine_object *) cd;
    enif_release_resource(obj->repo);
    git_object_free(obj->obj);
}

ERL_NIF_TERM git_engine_object_type2atom(const git_otype type)
{
    switch(type) {
    case GIT_OBJ_COMMIT:
        return atoms.commit;
    case GIT_OBJ_TREE:
        return atoms.tree;
    case GIT_OBJ_BLOB:
        return atoms.blob;
    case GIT_OBJ_TAG:
        return atoms.tag;
    case GIT_OBJ_ANY:
        return atoms.undefined;
    default:
        return atoms.error;
    }
}

git_otype git_engine_object_atom2type(ERL_NIF_TERM term)
{
    if (!enif_compare(term, atoms.commit))
        return GIT_OBJ_COMMIT;
    else if (!enif_compare(term, atoms.tree))
        return GIT_OBJ_TREE;
    else if (!enif_compare(term, atoms.blob))
        return GIT_OBJ_BLOB;
    else if (!enif_compare(term, atoms.tag))
        return GIT_OBJ_TAG;
    else if (!enif_compare(term, atoms.undefined))
        return GIT_OBJ_ANY;

    return GIT_OBJ_BAD;
}

ERL_NIF_TERM
git_engine_object_repository(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    git_engine_object *obj;
    git_engine_repository *res_repo;
    ERL_NIF_TERM term_repo;

    if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
        return enif_make_badarg(env);

    res_repo = obj->repo;
    term_repo = enif_make_resource(env, res_repo);

    return enif_make_tuple2(env, atoms.ok, term_repo);
}

ERL_NIF_TERM
git_engine_object_lookup(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int error;
    git_engine_repository *repo;
    ErlNifBinary bin;
    git_oid id;
    git_engine_object *obj;
    ERL_NIF_TERM term_obj;

    if (!enif_get_resource(env, argv[0], git_engine_repository_type, (void **) &repo))
        return enif_make_badarg(env);

    if (!enif_inspect_binary(env, argv[1], &bin))
        return enif_make_badarg(env);

    if (bin.size != GIT_OID_RAWSZ)
        return enif_make_badarg(env);

    git_oid_fromraw(&id, bin.data);

    obj = enif_alloc_resource(git_engine_object_type, sizeof(git_engine_object));
    if (!obj)
        return git_engine_oom(env);

    error = git_object_lookup(&obj->obj, repo->repo, &id, GIT_OBJ_ANY);
    if (error < 0)
        return git_engine_error_struct(env, error);

    term_obj = enif_make_resource(env, obj);
    enif_release_resource(obj);

    obj->repo = repo;
    enif_keep_resource(repo);

    return enif_make_tuple3(env, atoms.ok, git_engine_object_type2atom(git_object_type(obj->obj)), term_obj);
}

ERL_NIF_TERM
git_engine_object_id(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary bin;
    const git_oid *id;
    git_engine_object *obj;

    if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
        return enif_make_badarg(env);

    id = git_object_id(obj->obj);

    if (git_engine_oid_bin(&bin, id) < 0)
        return git_engine_oom(env);

    return enif_make_tuple2(env, atoms.ok, enif_make_binary(env, &bin));
}

ERL_NIF_TERM
git_engine_object_zlib_inflate(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary input, bin;
    ERL_NIF_TERM chunks, data;
    unsigned int chunk_size;
    int error;
    z_stream z;
    z.zalloc = Z_NULL;
    z.zfree = Z_NULL;
    z.opaque = Z_NULL;

    if (!enif_inspect_binary(env, argv[0], &input))
        return enif_make_badarg(env);

    if (!git_engine_terminate_binary(&input)) {
        enif_release_binary(&input);
        return git_engine_oom(env);
    }

	if (!enif_get_uint(env, argv[1], &chunk_size))
		return enif_make_badarg(env);

    z.avail_in = input.size;
    z.next_in = input.data;

    if (inflateInit(&z) != Z_OK)
        return git_engine_oom(env);

    chunks = enif_make_list(env, 0);
    unsigned char chunk[chunk_size];
    enif_alloc_binary(chunk_size, &bin);

    do {
        z.avail_out = chunk_size;
        z.next_out = chunk;

        error = inflate(&z, Z_NO_FLUSH);
        switch (error) {
            case Z_NEED_DICT:
                inflateEnd(&z);
                enif_release_binary(&input);
                enif_release_binary(&bin);
                git_engine_string_to_bin(&bin, z.msg);
                return enif_make_tuple2(env, atoms.error, enif_make_tuple2(env, atoms.zlib_need_dict, enif_make_binary(env, &bin)));
            case Z_DATA_ERROR:
                inflateEnd(&z);
                enif_release_binary(&input);
                enif_release_binary(&bin);
                git_engine_string_to_bin(&bin, z.msg);
                return enif_make_tuple2(env, atoms.error, enif_make_tuple2(env, atoms.zlib_data_error, enif_make_binary(env, &bin)));
            case Z_STREAM_ERROR:
                inflateEnd(&z);
                enif_release_binary(&input);
                enif_release_binary(&bin);
                git_engine_string_to_bin(&bin, z.msg);
                return enif_make_tuple2(env, atoms.error, enif_make_tuple2(env, atoms.zlib_stream_error, enif_make_binary(env, &bin)));
            case Z_MEM_ERROR:
                enif_release_binary(&input);
                inflateEnd(&z);
                return git_engine_oom(env);
        }

        if (!enif_realloc_binary(&bin, chunk_size-z.avail_out)) {
            inflateEnd(&z);
            enif_release_binary(&input);
            return git_engine_oom(env);
        }
        memmove(bin.data, chunk, bin.size);
        chunks = enif_make_list_cell(env, enif_make_binary(env, &bin), chunks);

    } while (z.avail_out == 0);

    inflateEnd(&z);
    enif_release_binary(&input);

    if(enif_make_reverse_list(env, chunks, &data) < 0) {
        return git_engine_oom(env);
    }

    return enif_make_tuple3(env, atoms.ok, data, enif_make_ulong(env, z.total_in));
}

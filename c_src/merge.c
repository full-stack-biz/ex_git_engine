#include "geef.h"
#include "merge.h"
#include "repository.h"
#include "object.h"
#include "index.h"
#include "oid.h"
#include <git2.h>

ERL_NIF_TERM
geef_merge_commits(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	geef_repository *repo;
	geef_object *our_commit, *their_commit;
	geef_index *index;
	ERL_NIF_TERM term;
	git_merge_options opts = GIT_MERGE_OPTIONS_INIT;

	if (!enif_get_resource(env, argv[0], geef_repository_type, (void **) &repo))
		return enif_make_badarg(env);

	if (!enif_get_resource(env, argv[1], geef_object_type, (void **) &our_commit))
		return enif_make_badarg(env);

	if (!enif_get_resource(env, argv[2], geef_object_type, (void **) &their_commit))
		return enif_make_badarg(env);

	index = enif_alloc_resource(geef_index_type, sizeof(geef_index));
	if (!index)
		return geef_oom(env);

	error = git_merge_commits(&index->index, repo->repo,
	                          (git_commit *) our_commit->obj,
	                          (git_commit *) their_commit->obj,
	                          &opts);

	if (error < 0) {
		enif_release_resource(index);
		return geef_error_struct(env, error);
	}

	if (git_index_has_conflicts(index->index)) {
		git_index_free(index->index);
		index->index = NULL;
		enif_release_resource(index);
		return enif_make_tuple2(env, atoms.error, enif_make_atom(env, "conflict"));
	}

	term = enif_make_resource(env, index);
	enif_release_resource(index);

	return enif_make_tuple2(env, atoms.ok, term);
}

ERL_NIF_TERM
geef_merge_base(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	geef_repository *repo;
	ErlNifBinary bin1, bin2, out;
	git_oid oid1, oid2, base_oid;

	if (!enif_get_resource(env, argv[0], geef_repository_type, (void **) &repo))
		return enif_make_badarg(env);

	if (!enif_inspect_binary(env, argv[1], &bin1))
		return enif_make_badarg(env);
	if (bin1.size != GIT_OID_RAWSZ)
		return enif_make_badarg(env);
	git_oid_fromraw(&oid1, bin1.data);

	if (!enif_inspect_binary(env, argv[2], &bin2))
		return enif_make_badarg(env);
	if (bin2.size != GIT_OID_RAWSZ)
		return enif_make_badarg(env);
	git_oid_fromraw(&oid2, bin2.data);

	error = git_merge_base(&base_oid, repo->repo, &oid1, &oid2);
	if (error < 0)
		return geef_error_struct(env, error);

	if (geef_oid_bin(&out, &base_oid) < 0)
		return geef_oom(env);

	return enif_make_tuple2(env, atoms.ok, enif_make_binary(env, &out));
}

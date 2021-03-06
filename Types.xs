/* This file is part of the Lexical-Types Perl module.
 * See http://search.cpan.org/dist/Lexical-Types/ */

#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define __PACKAGE__     "Lexical::Types"
#define __PACKAGE_LEN__ (sizeof(__PACKAGE__)-1)

/* --- Compatibility wrappers ---------------------------------------------- */

#define LT_HAS_PERL(R, V, S) (PERL_REVISION > (R) || (PERL_REVISION == (R) && (PERL_VERSION > (V) || (PERL_VERSION == (V) && (PERL_SUBVERSION >= (S))))))

#if LT_HAS_PERL(5, 10, 0) || defined(PL_parser)
# ifndef PL_in_my_stash
#  define PL_in_my_stash PL_parser->in_my_stash
# endif
#else
# ifndef PL_in_my_stash
#  define PL_in_my_stash PL_Iin_my_stash
# endif
#endif

#ifndef LT_WORKAROUND_REQUIRE_PROPAGATION
# define LT_WORKAROUND_REQUIRE_PROPAGATION !LT_HAS_PERL(5, 10, 1)
#endif

#ifndef LT_HAS_RPEEP
# define LT_HAS_RPEEP LT_HAS_PERL(5, 13, 5)
#endif

#ifndef HvNAME_get
# define HvNAME_get(H) HvNAME(H)
#endif

#ifndef HvNAMELEN_get
# define HvNAMELEN_get(H) strlen(HvNAME_get(H))
#endif

#ifndef OP_SIBLING
# define OP_SIBLING(O) ((O)->op_sibling)
#endif

#ifndef SvREFCNT_inc_simple_void_NN
# define SvREFCNT_inc_simple_void_NN(S) ((void) SvREFCNT_inc(S))
#endif

/* ... Thread safety and multiplicity ...................................... */

/* Safe unless stated otherwise in Makefile.PL */
#ifndef LT_FORKSAFE
# define LT_FORKSAFE 1
#endif

#ifndef LT_MULTIPLICITY
# if defined(MULTIPLICITY) || defined(PERL_IMPLICIT_CONTEXT)
#  define LT_MULTIPLICITY 1
# else
#  define LT_MULTIPLICITY 0
# endif
#endif

#ifndef tTHX
# define tTHX PerlInterpreter*
#endif

#if LT_MULTIPLICITY && defined(USE_ITHREADS) && defined(dMY_CXT) && defined(MY_CXT) && defined(START_MY_CXT) && defined(MY_CXT_INIT) && (defined(MY_CXT_CLONE) || defined(dMY_CXT_SV))
# define LT_THREADSAFE 1
# ifndef MY_CXT_CLONE
#  define MY_CXT_CLONE \
    dMY_CXT_SV;                                                      \
    my_cxt_t *my_cxtp = (my_cxt_t*)SvPVX(newSV(sizeof(my_cxt_t)-1)); \
    Copy(INT2PTR(my_cxt_t*, SvUV(my_cxt_sv)), my_cxtp, 1, my_cxt_t); \
    sv_setuv(my_cxt_sv, PTR2UV(my_cxtp))
# endif
#else
# define LT_THREADSAFE 0
# undef  dMY_CXT
# define dMY_CXT      dNOOP
# undef  MY_CXT
# define MY_CXT       lt_globaldata
# undef  START_MY_CXT
# define START_MY_CXT STATIC my_cxt_t MY_CXT;
# undef  MY_CXT_INIT
# define MY_CXT_INIT  NOOP
# undef  MY_CXT_CLONE
# define MY_CXT_CLONE NOOP
# undef  pMY_CXT
# define pMY_CXT
# undef  pMY_CXT_
# define pMY_CXT_
# undef  aMY_CXT
# define aMY_CXT
# undef  aMY_CXT_
# define aMY_CXT_
#endif

#if defined(OP_CHECK_MUTEX_LOCK) && defined(OP_CHECK_MUTEX_UNLOCK)
# define LT_CHECK_MUTEX_LOCK   OP_CHECK_MUTEX_LOCK
# define LT_CHECK_MUTEX_UNLOCK OP_CHECK_MUTEX_UNLOCK
#else
# define LT_CHECK_MUTEX_LOCK   OP_REFCNT_LOCK
# define LT_CHECK_MUTEX_UNLOCK OP_REFCNT_UNLOCK
#endif

typedef OP *(*lt_ck_t)(pTHX_ OP *);

#ifdef wrap_op_checker

# define lt_ck_replace(T, NC, OCP) wrap_op_checker((T), (NC), (OCP))

#else

STATIC void lt_ck_replace(pTHX_ OPCODE type, lt_ck_t new_ck, lt_ck_t *old_ck_p){
#define lt_ck_replace(T, NC, OCP) lt_ck_replace(aTHX_ (T), (NC), (OCP))
 LT_CHECK_MUTEX_LOCK;
 if (!*old_ck_p) {
  *old_ck_p      = PL_check[type];
  PL_check[type] = new_ck;
 }
 LT_CHECK_MUTEX_UNLOCK;
}

#endif

STATIC void lt_ck_restore(pTHX_ OPCODE type, lt_ck_t *old_ck_p) {
#define lt_ck_restore(T, OCP) lt_ck_restore(aTHX_ (T), (OCP))
 LT_CHECK_MUTEX_LOCK;
 if (*old_ck_p) {
  PL_check[type] = *old_ck_p;
  *old_ck_p      = 0;
 }
 LT_CHECK_MUTEX_UNLOCK;
}

/* --- Helpers ------------------------------------------------------------- */

/* ... Thread-safe hints ................................................... */

#if LT_WORKAROUND_REQUIRE_PROPAGATION

typedef struct {
 SV *code;
 IV  require_tag;
} lt_hint_t;

#define LT_HINT_STRUCT 1

#define LT_HINT_CODE(H) ((H)->code)

#define LT_HINT_FREE(H) { \
 lt_hint_t *h = (H);      \
 SvREFCNT_dec(h->code);   \
 PerlMemShared_free(h);   \
}

#else  /*  LT_WORKAROUND_REQUIRE_PROPAGATION */

typedef SV lt_hint_t;

#define LT_HINT_STRUCT 0

#define LT_HINT_CODE(H) (H)

#define LT_HINT_FREE(H) SvREFCNT_dec(H);

#endif /* !LT_WORKAROUND_REQUIRE_PROPAGATION */

#if LT_THREADSAFE

#define PTABLE_NAME        ptable_hints
#define PTABLE_VAL_FREE(V) LT_HINT_FREE(V)

#define pPTBL  pTHX
#define pPTBL_ pTHX_
#define aPTBL  aTHX
#define aPTBL_ aTHX_

#include "ptable.h"

#define ptable_hints_store(T, K, V) ptable_hints_store(aTHX_ (T), (K), (V))
#define ptable_hints_free(T)        ptable_hints_free(aTHX_ (T))

#endif /* LT_THREADSAFE */

/* ... "Seen" pointer table ................................................ */

#define PTABLE_NAME        ptable_seen
#define PTABLE_VAL_FREE(V) NOOP

#include "ptable.h"

/* PerlMemShared_free() needs the [ap]PTBLMS_? default values */
#define ptable_seen_store(T, K, V) ptable_seen_store(aPTBLMS_ (T), (K), (V))
#define ptable_seen_clear(T)       ptable_seen_clear(aPTBLMS_ (T))
#define ptable_seen_free(T)        ptable_seen_free(aPTBLMS_ (T))

/* ... Global data ......................................................... */

#define MY_CXT_KEY __PACKAGE__ "::_guts" XS_VERSION

typedef struct {
#if LT_THREADSAFE
 ptable *tbl; /* It really is a ptable_hints */
 tTHX    owner;
#endif
 ptable *seen; /* It really is a ptable_seen */
 SV     *default_meth;
} my_cxt_t;

START_MY_CXT

/* ... Cloning global data ................................................. */

#if LT_THREADSAFE

typedef struct {
 ptable *tbl;
#if LT_HAS_PERL(5, 13, 2)
 CLONE_PARAMS *params;
#else
 CLONE_PARAMS params;
#endif
} lt_ptable_clone_ud;

#if LT_HAS_PERL(5, 13, 2)
# define lt_ptable_clone_ud_init(U, T, O) \
   (U).tbl    = (T); \
   (U).params = Perl_clone_params_new((O), aTHX)
# define lt_ptable_clone_ud_deinit(U) Perl_clone_params_del((U).params)
# define lt_dup_inc(S, U)             SvREFCNT_inc(sv_dup((S), (U)->params))
#else
# define lt_ptable_clone_ud_init(U, T, O) \
   (U).tbl               = (T);     \
   (U).params.stashes    = newAV(); \
   (U).params.flags      = 0;       \
   (U).params.proto_perl = (O)
# define lt_ptable_clone_ud_deinit(U) SvREFCNT_dec((U).params.stashes)
# define lt_dup_inc(S, U)             SvREFCNT_inc(sv_dup((S), &((U)->params)))
#endif

STATIC void lt_ptable_clone(pTHX_ ptable_ent *ent, void *ud_) {
 lt_ptable_clone_ud *ud = ud_;
 lt_hint_t *h1 = ent->val;
 lt_hint_t *h2;

#if LT_HINT_STRUCT

 h2              = PerlMemShared_malloc(sizeof *h2);
 h2->code        = lt_dup_inc(h1->code, ud);
#if LT_WORKAROUND_REQUIRE_PROPAGATION
 h2->require_tag = PTR2IV(lt_dup_inc(INT2PTR(SV *, h1->require_tag), ud));
#endif

#else /*   LT_HINT_STRUCT */

 h2 = lt_dup_inc(h1, ud);

#endif /* !LT_HINT_STRUCT */

 ptable_hints_store(ud->tbl, ent->key, h2);
}

STATIC void lt_thread_cleanup(pTHX_ void *ud) {
 dMY_CXT;

 ptable_hints_free(MY_CXT.tbl);
 MY_CXT.tbl          = NULL;
 ptable_seen_free(MY_CXT.seen);
 MY_CXT.seen         = NULL;
 SvREFCNT_dec(MY_CXT.default_meth);
 MY_CXT.default_meth = NULL;
}

STATIC int lt_endav_free(pTHX_ SV *sv, MAGIC *mg) {
 SAVEDESTRUCTOR_X(lt_thread_cleanup, NULL);

 return 0;
}

STATIC MGVTBL lt_endav_vtbl = {
 0,
 0,
 0,
 0,
 lt_endav_free
#if MGf_COPY
 , 0
#endif
#if MGf_DUP
 , 0
#endif
#if MGf_LOCAL
 , 0
#endif
};

#endif /* LT_THREADSAFE */

/* ... Hint tags ........................................................... */

#if LT_WORKAROUND_REQUIRE_PROPAGATION

STATIC IV lt_require_tag(pTHX) {
#define lt_require_tag() lt_require_tag(aTHX)
 const CV *cv, *outside;

 cv = PL_compcv;

 if (!cv) {
  /* If for some reason the pragma is operational at run-time, try to discover
   * the current cv in use. */
  const PERL_SI *si;

  for (si = PL_curstackinfo; si; si = si->si_prev) {
   I32 cxix;

   for (cxix = si->si_cxix; cxix >= 0; --cxix) {
    const PERL_CONTEXT *cx = si->si_cxstack + cxix;

    switch (CxTYPE(cx)) {
     case CXt_SUB:
     case CXt_FORMAT:
      /* The propagation workaround is only needed up to 5.10.0 and at that
       * time format and sub contexts were still identical. And even later the
       * cv members offsets should have been kept the same. */
      cv = cx->blk_sub.cv;
      goto get_enclosing_cv;
     case CXt_EVAL:
      cv = cx->blk_eval.cv;
      goto get_enclosing_cv;
     default:
      break;
    }
   }
  }

  cv = PL_main_cv;
 }

get_enclosing_cv:
 for (outside = CvOUTSIDE(cv); outside; outside = CvOUTSIDE(cv))
  cv = outside;

 return PTR2IV(cv);
}

#endif /* LT_WORKAROUND_REQUIRE_PROPAGATION */

STATIC SV *lt_tag(pTHX_ SV *value) {
#define lt_tag(V) lt_tag(aTHX_ (V))
 lt_hint_t *h;
 SV        *code = NULL;
#if LT_THREADSAFE
 dMY_CXT;

 if (!MY_CXT.tbl)
  return newSViv(0);
#endif /* LT_THREADSAFE */

 if (SvROK(value)) {
  value = SvRV(value);
  if (SvTYPE(value) >= SVt_PVCV) {
   code = value;
   SvREFCNT_inc_simple_void_NN(code);
  }
 }

#if LT_HINT_STRUCT
 h = PerlMemShared_malloc(sizeof *h);
 h->code        = code;
# if LT_WORKAROUND_REQUIRE_PROPAGATION
 h->require_tag = lt_require_tag();
# endif /* LT_WORKAROUND_REQUIRE_PROPAGATION */
#else  /*  LT_HINT_STRUCT */
 h = code;
#endif /* !LT_HINT_STRUCT */

#if LT_THREADSAFE
 /* We only need for the key to be an unique tag for looking up the value later
  * Allocated memory provides convenient unique identifiers, so that's why we
  * use the hint as the key itself. */
 ptable_hints_store(MY_CXT.tbl, h, h);
#endif /* LT_THREADSAFE */

 return newSViv(PTR2IV(h));
}

STATIC SV *lt_detag(pTHX_ const SV *hint) {
#define lt_detag(H) lt_detag(aTHX_ (H))
 lt_hint_t *h;
#if LT_THREADSAFE
 dMY_CXT;

 if (!MY_CXT.tbl)
  return NULL;
#endif /* LT_THREADSAFE */

 if (!(hint && SvIOK(hint)))
  return NULL;

 h = INT2PTR(lt_hint_t *, SvIVX(hint));
#if LT_THREADSAFE
 h = ptable_fetch(MY_CXT.tbl, h);
#endif /* LT_THREADSAFE */
#if LT_WORKAROUND_REQUIRE_PROPAGATION
 if (lt_require_tag() != h->require_tag)
  return NULL;
#endif /* LT_WORKAROUND_REQUIRE_PROPAGATION */

 return LT_HINT_CODE(h);
}

STATIC U32 lt_hash = 0;

STATIC SV *lt_hint(pTHX) {
#define lt_hint() lt_hint(aTHX)
 SV *hint;
#ifdef cop_hints_fetch_pvn
 hint = cop_hints_fetch_pvn(PL_curcop, __PACKAGE__, __PACKAGE_LEN__, lt_hash,0);
#elif LT_HAS_PERL(5, 9, 5)
 hint = Perl_refcounted_he_fetch(aTHX_ PL_curcop->cop_hints_hash,
                                       NULL,
                                       __PACKAGE__, __PACKAGE_LEN__,
                                       0,
                                       lt_hash);
#else
 SV **val = hv_fetch(GvHV(PL_hintgv), __PACKAGE__, __PACKAGE_LEN__, 0);
 if (!val)
  return 0;
 hint = *val;
#endif
 return lt_detag(hint);
}

/* ... op => info map ...................................................... */

#define PTABLE_NAME        ptable_map
#define PTABLE_VAL_FREE(V) PerlMemShared_free(V)

#include "ptable.h"

/* PerlMemShared_free() needs the [ap]PTBLMS_? default values */
#define ptable_map_store(T, K, V) ptable_map_store(aPTBLMS_ (T), (K), (V))
#define ptable_map_delete(T, K)   ptable_map_delete(aPTBLMS_ (T), (K))

#ifdef USE_ITHREADS

STATIC perl_mutex lt_op_map_mutex;

#define LT_LOCK(M)   MUTEX_LOCK(M)
#define LT_UNLOCK(M) MUTEX_UNLOCK(M)

#else /* USE_ITHREADS */

#define LT_LOCK(M)
#define LT_UNLOCK(M)

#endif /* !USE_ITHREADS */

STATIC ptable *lt_op_padxv_map = NULL;

typedef struct {
 OP *(*old_pp)(pTHX);
#ifdef MULTIPLICITY
 STRLEN buf_size, orig_pkg_len, type_pkg_len, type_meth_len;
 char *buf;
#else /* MULTIPLICITY */
 SV *orig_pkg;
 SV *type_pkg;
 SV *type_meth;
#endif /* !MULTIPLICITY */
} lt_op_padxv_info;

STATIC void lt_op_padxv_info_call(pTHX_ const lt_op_padxv_info *oi, SV *sv) {
#define lt_op_padxv_info_call(O, S) lt_op_padxv_info_call(aTHX_ (O), (S))
 SV *orig_pkg, *type_pkg, *type_meth;
 int items;
 dSP;

 ENTER;
 SAVETMPS;

#ifdef MULTIPLICITY
 {
  STRLEN op_len = oi->orig_pkg_len, tp_len = oi->type_pkg_len;
  char *buf = oi->buf;
  orig_pkg  = sv_2mortal(newSVpvn(buf, op_len));
  SvREADONLY_on(orig_pkg);
  buf      += op_len;
  type_pkg  = sv_2mortal(newSVpvn(buf, tp_len));
  SvREADONLY_on(type_pkg);
  buf      += tp_len;
  type_meth = sv_2mortal(newSVpvn(buf, oi->type_meth_len));
  SvREADONLY_on(type_meth);
 }
#else /* MULTIPLICITY */
 orig_pkg  = oi->orig_pkg;
 type_pkg  = oi->type_pkg;
 type_meth = oi->type_meth;
#endif /* !MULTIPLICITY */

 PUSHMARK(SP);
 EXTEND(SP, 3);
 PUSHs(type_pkg);
 PUSHs(sv);
 PUSHs(orig_pkg);
 PUTBACK;

 items = call_sv(type_meth, G_ARRAY | G_METHOD);

 SPAGAIN;
 switch (items) {
  case 0:
   break;
  case 1:
   sv_setsv(sv, POPs);
   break;
  default:
   croak("Typed scalar initializer method should return zero or one scalar, but got %d", items);
 }
 PUTBACK;

 FREETMPS;
 LEAVE;

 return;
}

STATIC void lt_padxv_map_store(pTHX_ const OP *o, SV *orig_pkg, SV *type_pkg, SV *type_meth, OP *(*old_pp)(pTHX)) {
#define lt_padxv_map_store(O, OP, TP, TM, PP) lt_padxv_map_store(aTHX_ (O), (OP), (TP), (TM), (PP))
 lt_op_padxv_info *oi;

 LT_LOCK(&lt_op_map_mutex);

 if (!(oi = ptable_fetch(lt_op_padxv_map, o))) {
  oi = PerlMemShared_malloc(sizeof *oi);
  ptable_map_store(lt_op_padxv_map, o, oi);
#ifdef MULTIPLICITY
  oi->buf      = NULL;
  oi->buf_size = 0;
#else /* MULTIPLICITY */
 } else {
  SvREFCNT_dec(oi->orig_pkg);
  SvREFCNT_dec(oi->type_pkg);
  SvREFCNT_dec(oi->type_meth);
#endif /* !MULTIPLICITY */
 }

#ifdef MULTIPLICITY
 {
  STRLEN op_len       = SvCUR(orig_pkg);
  STRLEN tp_len       = SvCUR(type_pkg);
  STRLEN tm_len       = SvCUR(type_meth);
  STRLEN new_buf_size = op_len + tp_len + tm_len;
  char *buf;
  if (new_buf_size > oi->buf_size) {
   PerlMemShared_free(oi->buf);
   oi->buf      = PerlMemShared_malloc(new_buf_size);
   oi->buf_size = new_buf_size;
  }
  buf  = oi->buf;
  Copy(SvPVX(orig_pkg),  buf, op_len, char);
  buf += op_len;
  Copy(SvPVX(type_pkg),  buf, tp_len, char);
  buf += tp_len;
  Copy(SvPVX(type_meth), buf, tm_len, char);
  oi->orig_pkg_len  = op_len;
  oi->type_pkg_len  = tp_len;
  oi->type_meth_len = tm_len;
  SvREFCNT_dec(orig_pkg);
  SvREFCNT_dec(type_pkg);
  SvREFCNT_dec(type_meth);
 }
#else /* MULTIPLICITY */
 oi->orig_pkg  = orig_pkg;
 oi->type_pkg  = type_pkg;
 oi->type_meth = type_meth;
#endif /* !MULTIPLICITY */

 oi->old_pp = old_pp;

 LT_UNLOCK(&lt_op_map_mutex);
}

STATIC const lt_op_padxv_info *lt_padxv_map_fetch(const OP *o, lt_op_padxv_info *oi) {
 const lt_op_padxv_info *val;

 LT_LOCK(&lt_op_map_mutex);

 val = ptable_fetch(lt_op_padxv_map, o);
 if (val) {
  *oi = *val;
  val = oi;
 }

 LT_UNLOCK(&lt_op_map_mutex);

 return val;
}

#if LT_HAS_PERL(5, 17, 6)

STATIC ptable *lt_op_padrange_map = NULL;

typedef struct {
 OP *(*old_pp)(pTHX);
 const OP *padxv_start;
} lt_op_padrange_info;

STATIC void lt_padrange_map_store(pTHX_ const OP *o, const OP *s, OP *(*old_pp)(pTHX)) {
#define lt_padrange_map_store(O, S, PP) lt_padrange_map_store(aTHX_ (O), (S), (PP))
 lt_op_padrange_info *oi;

 LT_LOCK(&lt_op_map_mutex);

 if (!(oi = ptable_fetch(lt_op_padrange_map, o))) {
  oi = PerlMemShared_malloc(sizeof *oi);
  ptable_map_store(lt_op_padrange_map, o, oi);
 }

 oi->old_pp      = old_pp;
 oi->padxv_start = s;

 LT_UNLOCK(&lt_op_map_mutex);
}

STATIC const lt_op_padrange_info *lt_padrange_map_fetch(const OP *o, lt_op_padrange_info *oi) {
 const lt_op_padrange_info *val;

 LT_LOCK(&lt_op_map_mutex);

 val = ptable_fetch(lt_op_padrange_map, o);
 if (val) {
  *oi = *val;
  val = oi;
 }

 LT_UNLOCK(&lt_op_map_mutex);

 return val;
}

#endif

STATIC void lt_map_delete(pTHX_ const OP *o) {
#define lt_map_delete(O) lt_map_delete(aTHX_ (O))
 LT_LOCK(&lt_op_map_mutex);

 ptable_map_delete(lt_op_padxv_map,    o);
#if LT_HAS_PERL(5, 17, 6)
 ptable_map_delete(lt_op_padrange_map, o);
#endif

 LT_UNLOCK(&lt_op_map_mutex);
}

/* --- Hooks --------------------------------------------------------------- */

/* ... Our pp_padsv ........................................................ */

STATIC OP *lt_pp_padsv(pTHX) {
 lt_op_padxv_info oi;

 if (lt_padxv_map_fetch(PL_op, &oi)) {
  dTARGET;
  lt_op_padxv_info_call(&oi, TARG);
  return oi.old_pp(aTHX);
 }

 return PL_op->op_ppaddr(aTHX);
}

/* ... Our pp_padrange (on perl 5.17.6 and above) .......................... */

#if LT_HAS_PERL(5, 17, 6)

STATIC OP *lt_pp_padrange(pTHX) {
 lt_op_padrange_info roi;

 if (lt_padrange_map_fetch(PL_op, &roi)) {
  PADOFFSET i, base, count;
  const OP *p;

  base  = PL_op->op_targ;
  count = PL_op->op_private & OPpPADRANGE_COUNTMASK;

  for (i = 0, p = roi.padxv_start; i < count && p; ++i, p = OP_SIBLING(p)) {
   lt_op_padxv_info oi;
   if (p->op_type == OP_PADSV && lt_padxv_map_fetch(p, &oi))
    lt_op_padxv_info_call(&oi, PAD_SV(base + i));
  }

  return roi.old_pp(aTHX);
 }

 return PL_op->op_ppaddr(aTHX);
}

#endif

/* ... Our ck_pad{any,sv} .................................................. */

/* Sadly, the padsv OPs we are interested in don't trigger the padsv check
 * function, but are instead manually mutated from a padany. So we store
 * the op entry in the op map in the padany check function, and we set their
 * op_ppaddr member in our peephole optimizer replacement below. */

STATIC OP *(*lt_old_ck_padany)(pTHX_ OP *) = 0;

STATIC OP *lt_ck_padany(pTHX_ OP *o) {
 HV *stash;
 SV *code;

 o = lt_old_ck_padany(aTHX_ o);

 stash = PL_in_my_stash;
 if (stash && (code = lt_hint())) {
  dMY_CXT;
  SV *orig_pkg  = newSVpvn(HvNAME_get(stash), HvNAMELEN_get(stash));
  SV *orig_meth = MY_CXT.default_meth; /* Guarded by lt_hint() */
  SV *type_pkg  = NULL;
  SV *type_meth = NULL;
  int items;

  dSP;

  SvREADONLY_on(orig_pkg);

  ENTER;
  SAVETMPS;

  PUSHMARK(SP);
  EXTEND(SP, 2);
  PUSHs(orig_pkg);
  PUSHs(orig_meth);
  PUTBACK;

  items = call_sv(code, G_ARRAY);

  SPAGAIN;
  if (items > 2)
   croak(__PACKAGE__ " mangler should return zero, one or two scalars, but got %d", items);
  if (items == 0) {
   SvREFCNT_dec(orig_pkg);
   FREETMPS;
   LEAVE;
   goto skip;
  } else {
   SV *rsv;
   if (items > 1) {
    rsv = POPs;
    if (SvOK(rsv)) {
     type_meth = newSVsv(rsv);
     SvREADONLY_on(type_meth);
    }
   }
   rsv = POPs;
   if (SvOK(rsv)) {
    type_pkg = newSVsv(rsv);
    SvREADONLY_on(type_pkg);
   }
  }
  PUTBACK;

  FREETMPS;
  LEAVE;

  if (!type_pkg) {
   type_pkg = orig_pkg;
   SvREFCNT_inc_simple_void_NN(orig_pkg);
  }

  if (!type_meth) {
   type_meth = orig_meth;
   SvREFCNT_inc_simple_void_NN(orig_meth);
  }

  lt_padxv_map_store(o, orig_pkg, type_pkg, type_meth, o->op_ppaddr);
 } else {
skip:
  lt_map_delete(o);
 }

 return o;
}

STATIC OP *(*lt_old_ck_padsv)(pTHX_ OP *) = 0;

STATIC OP *lt_ck_padsv(pTHX_ OP *o) {
 lt_map_delete(o);

 return lt_old_ck_padsv(aTHX_ o);
}

/* ... Our peephole optimizer .............................................. */

#if LT_HAS_PERL(5, 17, 6)

STATIC int lt_maybe_padrange_setup(pTHX_ OP *o, const OP *start) {
#define lt_maybe_padrange_setup(O, S) lt_maybe_padrange_setup(aTHX_ (O), (S))
 PADOFFSET i, count;
 const OP *p;

 count = o->op_private & OPpPADRANGE_COUNTMASK;

 for (i = 0, p = start; i < count && p; ++i, p = OP_SIBLING(p)) {
  if (p->op_type == OP_PADSV) {
   /* In a padrange sequence, either all lexicals are typed, or none are.
    * Thus we can stop at the first padsv op. However, note that these
    * lexicals can need to call different methods in different packages. */
   LT_LOCK(&lt_op_map_mutex);
   if (ptable_fetch(lt_op_padxv_map, p)) {
    LT_UNLOCK(&lt_op_map_mutex);
    lt_padrange_map_store(o, start, o->op_ppaddr);
    o->op_ppaddr = lt_pp_padrange;
   } else {
    LT_UNLOCK(&lt_op_map_mutex);
   }
   return 1;
  }
 }

 return 0;
}

#endif

STATIC peep_t lt_old_peep = 0; /* This is actually the rpeep past 5.13.5 */

STATIC void lt_peep_rec(pTHX_ OP *o, ptable *seen) {
#define lt_peep_rec(O) lt_peep_rec(aTHX_ (O), seen)
 for (; o; o = o->op_next) {
  if (ptable_fetch(seen, o))
   break;
  ptable_seen_store(seen, o, o);

  switch (o->op_type) {
   case OP_PADSV:
    if (o->op_ppaddr != lt_pp_padsv && o->op_private & OPpLVAL_INTRO) {
     lt_op_padxv_info *oi;
     LT_LOCK(&lt_op_map_mutex);
     oi = ptable_fetch(lt_op_padxv_map, o);
     if (oi) {
      oi->old_pp   = o->op_ppaddr;
      o->op_ppaddr = lt_pp_padsv;
     }
     LT_UNLOCK(&lt_op_map_mutex);
    }
    break;
#if LT_HAS_PERL(5, 17, 6)
   case OP_PADRANGE:
    /* We deal with special padrange ops later, in the aassign op they belong
     * to. */
    if (o->op_ppaddr != lt_pp_padrange && o->op_private & OPpLVAL_INTRO
                                       && !(o->op_flags & OPf_SPECIAL)) {
     /* A padrange op is guaranteed to have previously been a pushmark.
      * Moreover, for non-special padrange ops (i.e. that aren't for
      * my (...) = @_), the original padxv ops are its siblings. */
     lt_maybe_padrange_setup(o, OP_SIBLING(o));
    }
    break;
   case OP_AASSIGN: {
    OP *op;
    if (cBINOPo->op_first && cBINOPo->op_first->op_flags & OPf_KIDS
                          && (op = cUNOPx(cBINOPo->op_first)->op_first)
                          && op->op_type == OP_PADRANGE
                          && op->op_ppaddr != lt_pp_padrange
                          && op->op_private & OPpLVAL_INTRO
                          && op->op_flags & OPf_SPECIAL) {
     const OP *start = cUNOPx(cBINOPo->op_last)->op_first;
     if (start->op_type == OP_PUSHMARK)
      start = OP_SIBLING(start);
     lt_maybe_padrange_setup(op, start);
    }
    break;
   }
#endif
#if !LT_HAS_RPEEP
   case OP_MAPWHILE:
   case OP_GREPWHILE:
   case OP_AND:
   case OP_OR:
   case OP_ANDASSIGN:
   case OP_ORASSIGN:
   case OP_COND_EXPR:
   case OP_RANGE:
# if LT_HAS_PERL(5, 10, 0)
   case OP_ONCE:
   case OP_DOR:
   case OP_DORASSIGN:
# endif
    lt_peep_rec(cLOGOPo->op_other);
    break;
   case OP_ENTERLOOP:
   case OP_ENTERITER:
    lt_peep_rec(cLOOPo->op_redoop);
    lt_peep_rec(cLOOPo->op_nextop);
    lt_peep_rec(cLOOPo->op_lastop);
    break;
# if LT_HAS_PERL(5, 9, 5)
   case OP_SUBST:
    lt_peep_rec(cPMOPo->op_pmstashstartu.op_pmreplstart);
    break;
# else
   case OP_QR:
   case OP_MATCH:
   case OP_SUBST:
    lt_peep_rec(cPMOPo->op_pmreplstart);
    break;
# endif
#endif /* !LT_HAS_RPEEP */
   default:
    break;
  }
 }
}

STATIC void lt_peep(pTHX_ OP *o) {
 dMY_CXT;
 ptable *seen = MY_CXT.seen;

 lt_old_peep(aTHX_ o);

 if (seen) {
  ptable_seen_clear(seen);
  lt_peep_rec(o);
  ptable_seen_clear(seen);
 }
}

/* --- Interpreter setup/teardown ------------------------------------------ */


STATIC U32 lt_initialized = 0;

STATIC void lt_teardown(pTHX_ void *root) {
 if (!lt_initialized)
  return;

#if LT_MULTIPLICITY
 if (aTHX != root)
  return;
#endif

 {
  dMY_CXT;
#if LT_THREADSAFE
  ptable_hints_free(MY_CXT.tbl);
  MY_CXT.tbl          = NULL;
#endif
  ptable_seen_free(MY_CXT.seen);
  MY_CXT.seen         = NULL;
  SvREFCNT_dec(MY_CXT.default_meth);
  MY_CXT.default_meth = NULL;
 }

 lt_ck_restore(OP_PADANY, &lt_old_ck_padany);
 lt_ck_restore(OP_PADSV,  &lt_old_ck_padsv);

#if LT_HAS_RPEEP
 PL_rpeepp   = lt_old_peep;
#else
 PL_peepp    = lt_old_peep;
#endif
 lt_old_peep = 0;

 lt_initialized = 0;
}

STATIC void lt_setup(pTHX) {
#define lt_setup() lt_setup(aTHX)
 if (lt_initialized)
  return;

 {
  MY_CXT_INIT;
#if LT_THREADSAFE
  MY_CXT.tbl          = ptable_new();
  MY_CXT.owner        = aTHX;
#endif
  MY_CXT.seen         = ptable_new();
  MY_CXT.default_meth = newSVpvn("TYPEDSCALAR", 11);
  SvREADONLY_on(MY_CXT.default_meth);
 }

 lt_ck_replace(OP_PADANY, lt_ck_padany, &lt_old_ck_padany);
 lt_ck_replace(OP_PADSV,  lt_ck_padsv,  &lt_old_ck_padsv);

#if LT_HAS_RPEEP
 lt_old_peep = PL_rpeepp;
 PL_rpeepp   = lt_peep;
#else
 lt_old_peep = PL_peepp;
 PL_peepp    = lt_peep;
#endif

#if LT_MULTIPLICITY
 call_atexit(lt_teardown, aTHX);
#else
 call_atexit(lt_teardown, NULL);
#endif

 lt_initialized = 1;
}

STATIC U32 lt_booted = 0;

/* --- XS ------------------------------------------------------------------ */

MODULE = Lexical::Types      PACKAGE = Lexical::Types

PROTOTYPES: ENABLE

BOOT:
{
 if (!lt_booted++) {
  HV *stash;

  lt_op_padxv_map    = ptable_new();
#if LT_HAS_PERL(5, 17, 6)
  lt_op_padrange_map = ptable_new();
#endif
#ifdef USE_ITHREADS
  MUTEX_INIT(&lt_op_map_mutex);
#endif

  PERL_HASH(lt_hash, __PACKAGE__, __PACKAGE_LEN__);

  stash = gv_stashpvn(__PACKAGE__, __PACKAGE_LEN__, 1);
  newCONSTSUB(stash, "LT_THREADSAFE", newSVuv(LT_THREADSAFE));
  newCONSTSUB(stash, "LT_FORKSAFE",   newSVuv(LT_FORKSAFE));
 }

 lt_setup();
}

#if LT_THREADSAFE

void
CLONE(...)
PROTOTYPE: DISABLE
PREINIT:
 ptable *t;
 ptable *s;
 SV     *cloned_default_meth;
 GV     *gv;
PPCODE:
 {
  {
   lt_ptable_clone_ud ud;
   dMY_CXT;

   t = ptable_new();
   lt_ptable_clone_ud_init(ud, t, MY_CXT.owner);
   ptable_walk(MY_CXT.tbl, lt_ptable_clone, &ud);
   cloned_default_meth = lt_dup_inc(MY_CXT.default_meth, &ud);
   lt_ptable_clone_ud_deinit(ud);
  }
  s = ptable_new();
 }
 {
  MY_CXT_CLONE;
  MY_CXT.tbl          = t;
  MY_CXT.owner        = aTHX;
  MY_CXT.seen         = s;
  MY_CXT.default_meth = cloned_default_meth;
 }
 gv = gv_fetchpv(__PACKAGE__ "::_THREAD_CLEANUP", 0, SVt_PVCV);
 if (gv) {
  CV *cv = GvCV(gv);
  if (!PL_endav)
   PL_endav = newAV();
  SvREFCNT_inc(cv);
  if (!av_store(PL_endav, av_len(PL_endav) + 1, (SV *) cv))
   SvREFCNT_dec(cv);
  sv_magicext((SV *) PL_endav, NULL, PERL_MAGIC_ext, &lt_endav_vtbl, NULL, 0);
 }
 XSRETURN(0);

void
_THREAD_CLEANUP(...)
PROTOTYPE: DISABLE
PPCODE:
 lt_thread_cleanup(aTHX_ NULL);
 XSRETURN(0);

#endif

SV *
_tag(SV *value)
PROTOTYPE: $
CODE:
 RETVAL = lt_tag(value);
OUTPUT:
 RETVAL

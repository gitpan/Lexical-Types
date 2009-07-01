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

#ifndef HvNAME_get
# define HvNAME_get(H) HvNAME(H)
#endif

#ifndef HvNAMELEN_get
# define HvNAMELEN_get(H) strlen(HvNAME_get(H))
#endif

#ifndef SvIS_FREED
# define SvIS_FREED(sv) ((sv)->sv_flags == SVTYPEMASK)
#endif

/* ... Thread safety and multiplicity ...................................... */

#ifndef LT_MULTIPLICITY
# if defined(MULTIPLICITY) || defined(PERL_IMPLICIT_CONTEXT)
#  define LT_MULTIPLICITY 1
# else
#  define LT_MULTIPLICITY 0
# endif
#endif
#if LT_MULTIPLICITY && !defined(tTHX)
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
#endif

/* --- Helpers ------------------------------------------------------------- */

/* ... Thread-safe hints ................................................... */

/* If any of those is true, we need to store the hint in a global table. */

#if LT_THREADSAFE || LT_WORKAROUND_REQUIRE_PROPAGATION

typedef struct {
 SV *code;
#if LT_WORKAROUND_REQUIRE_PROPAGATION
 UV  requires;
#endif
} lt_hint_t;

#define PTABLE_NAME        ptable_hints
#define PTABLE_VAL_FREE(V) { lt_hint_t *h = (V); SvREFCNT_dec(h->code); PerlMemShared_free(h); }

#define pPTBL  pTHX
#define pPTBL_ pTHX_
#define aPTBL  aTHX
#define aPTBL_ aTHX_

#include "ptable.h"

#define ptable_hints_store(T, K, V) ptable_hints_store(aTHX_ (T), (K), (V))
#define ptable_hints_free(T)        ptable_hints_free(aTHX_ (T))

#define MY_CXT_KEY __PACKAGE__ "::_guts" XS_VERSION

typedef struct {
 ptable *tbl; /* It really is a ptable_hints */
#if LT_THREADSAFE
 tTHX    owner;
#endif
} my_cxt_t;

START_MY_CXT

#if LT_THREADSAFE

STATIC void lt_ptable_hints_clone(pTHX_ ptable_ent *ent, void *ud_) {
 my_cxt_t  *ud  = ud_;
 lt_hint_t *h1 = ent->val;
 lt_hint_t *h2 = PerlMemShared_malloc(sizeof *h2);

 *h2 = *h1;

 if (ud->owner != aTHX) {
  SV *val = h1->code;
  CLONE_PARAMS param;
  AV *stashes = (SvTYPE(val) == SVt_PVHV && HvNAME_get(val)) ? newAV() : NULL;
  param.stashes    = stashes;
  param.flags      = 0;
  param.proto_perl = ud->owner;
  h2->code = sv_dup(val, &param);
  if (stashes) {
   av_undef(stashes);
   SvREFCNT_dec(stashes);
  }
 }

 ptable_hints_store(ud->tbl, ent->key, h2);
 SvREFCNT_inc(h2->code);
}

STATIC void lt_thread_cleanup(pTHX_ void *);

STATIC void lt_thread_cleanup(pTHX_ void *ud) {
 int *level = ud;

 if (*level) {
  *level = 0;
  LEAVE;
  SAVEDESTRUCTOR_X(lt_thread_cleanup, level);
  ENTER;
 } else {
  dMY_CXT;
  PerlMemShared_free(level);
  ptable_hints_free(MY_CXT.tbl);
 }
}

#endif /* LT_THREADSAFE */

STATIC SV *lt_tag(pTHX_ SV *value) {
#define lt_tag(V) lt_tag(aTHX_ (V))
 lt_hint_t *h;
 dMY_CXT;

 value = SvOK(value) && SvROK(value) ? SvRV(value) : NULL;

 h = PerlMemShared_malloc(sizeof *h);
 h->code = SvREFCNT_inc(value);

#if LT_WORKAROUND_REQUIRE_PROPAGATION
 {
  const PERL_SI *si;
  UV             requires = 0;

  for (si = PL_curstackinfo; si; si = si->si_prev) {
   I32 cxix;

   for (cxix = si->si_cxix; cxix >= 0; --cxix) {
    const PERL_CONTEXT *cx = si->si_cxstack + cxix;

    if (CxTYPE(cx) == CXt_EVAL && cx->blk_eval.old_op_type == OP_REQUIRE)
     ++requires;
   }
  }

  h->requires = requires;
 }
#endif

 /* We only need for the key to be an unique tag for looking up the value later.
  * Allocated memory provides convenient unique identifiers, so that's why we
  * use the value pointer as the key itself. */
 ptable_hints_store(MY_CXT.tbl, value, h);

 return newSVuv(PTR2UV(value));
}

STATIC SV *lt_detag(pTHX_ const SV *hint) {
#define lt_detag(H) lt_detag(aTHX_ (H))
 lt_hint_t *h;
 dMY_CXT;

 if (!(hint && SvOK(hint) && SvIOK(hint)))
  return NULL;

 h = ptable_fetch(MY_CXT.tbl, INT2PTR(void *, SvUVX(hint)));

#if LT_WORKAROUND_REQUIRE_PROPAGATION
 {
  const PERL_SI *si;
  UV             requires = 0;

  for (si = PL_curstackinfo; si; si = si->si_prev) {
   I32 cxix;

   for (cxix = si->si_cxix; cxix >= 0; --cxix) {
    const PERL_CONTEXT *cx = si->si_cxstack + cxix;

    if (CxTYPE(cx) == CXt_EVAL && cx->blk_eval.old_op_type == OP_REQUIRE
                               && ++requires > h->requires)
     return NULL;
   }
  }
 }
#endif

 return h->code;
}

#else

STATIC SV *lt_tag(pTHX_ SV *value) {
#define lt_tag(V) lt_tag(aTHX_ (V))
 UV tag = 0;

 if (SvOK(value) && SvROK(value)) {
  value = SvRV(value);
  SvREFCNT_inc(value);
  tag = PTR2UV(value);
 }

 return newSVuv(tag);
}

#define lt_detag(H) (((H) && SvOK(H)) ? INT2PTR(SV *, SvUVX(H)) : NULL)

#endif /* LT_THREADSAFE || LT_WORKAROUND_REQUIRE_PROPAGATION */

STATIC U32 lt_hash = 0;

STATIC SV *lt_hint(pTHX) {
#define lt_hint() lt_hint(aTHX)
 SV *hint;
#if LT_HAS_PERL(5, 9, 5)
 hint = Perl_refcounted_he_fetch(aTHX_ PL_curcop->cop_hints_hash,
                                       NULL,
                                       __PACKAGE__, __PACKAGE_LEN__,
                                       0,
                                       lt_hash);
#else
 SV **val = hv_fetch(GvHV(PL_hintgv), __PACKAGE__, __PACKAGE_LEN__, lt_hash);
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

STATIC ptable *lt_op_map = NULL;

#ifdef USE_ITHREADS
STATIC perl_mutex lt_op_map_mutex;
#endif

typedef struct {
 SV *orig_pkg;
 SV *type_pkg;
 SV *type_meth;
 OP *(*pp_padsv)(pTHX);
} lt_op_info;

STATIC void lt_map_store(pPTBLMS_ const OP *o, SV *orig_pkg, SV *type_pkg, SV *type_meth, OP *(*pp_padsv)(pTHX)) {
#define lt_map_store(O, OP, TP, TM, PP) lt_map_store(aPTBLMS_ (O), (OP), (TP), (TM), (PP))
 lt_op_info *oi;

#ifdef USE_ITHREADS
 MUTEX_LOCK(&lt_op_map_mutex);
#endif

 if (!(oi = ptable_fetch(lt_op_map, o))) {
  oi = PerlMemShared_malloc(sizeof *oi);
  ptable_map_store(lt_op_map, o, oi);
 }

 oi->orig_pkg  = orig_pkg;
 oi->type_pkg  = type_pkg;
 oi->type_meth = type_meth;
 oi->pp_padsv  = pp_padsv;

#ifdef USE_ITHREADS
 MUTEX_UNLOCK(&lt_op_map_mutex);
#endif
}

STATIC const lt_op_info *lt_map_fetch(const OP *o, lt_op_info *oi) {
 const lt_op_info *val;

#ifdef USE_ITHREADS
 MUTEX_LOCK(&lt_op_map_mutex);
#endif

 val = ptable_fetch(lt_op_map, o);
 if (val) {
  *oi = *val;
  val = oi;
 }

#ifdef USE_ITHREADS
 MUTEX_UNLOCK(&lt_op_map_mutex);
#endif

 return val;
}

STATIC void lt_map_delete(pTHX_ const OP *o) {
#define lt_map_delete(O) lt_map_delete(aTHX_ (O))
#ifdef USE_ITHREADS
 MUTEX_LOCK(&lt_op_map_mutex);
#endif

 ptable_map_store(lt_op_map, o, NULL);

#ifdef USE_ITHREADS
 MUTEX_UNLOCK(&lt_op_map_mutex);
#endif
}

/* --- Hooks --------------------------------------------------------------- */

/* ... Our pp_padsv ........................................................ */

STATIC OP *lt_pp_padsv(pTHX) {
 lt_op_info oi;

 if ((PL_op->op_private & OPpLVAL_INTRO) && lt_map_fetch(PL_op, &oi)) {
  PADOFFSET targ = PL_op->op_targ;
  SV *sv         = PAD_SVl(targ);

  if (sv) {
   int items;
   dSP;

   ENTER;
   SAVETMPS;

   PUSHMARK(SP);
   EXTEND(SP, 3);
   PUSHs(oi.type_pkg);
   PUSHs(sv);
   PUSHs(oi.orig_pkg);
   PUTBACK;

   items = call_sv(oi.type_meth, G_ARRAY | G_METHOD);

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
  }

  return CALL_FPTR(oi.pp_padsv)(aTHX);
 }

 return CALL_FPTR(PL_ppaddr[OP_PADSV])(aTHX);
}

STATIC OP *(*lt_pp_padsv_saved)(pTHX) = 0;

STATIC void lt_pp_padsv_save(void) {
 if (lt_pp_padsv_saved)
  return;

 lt_pp_padsv_saved   = PL_ppaddr[OP_PADSV];
 PL_ppaddr[OP_PADSV] = lt_pp_padsv;
}

STATIC void lt_pp_padsv_restore(OP *o) {
 if (!lt_pp_padsv_saved)
  return;

 if (o->op_ppaddr == lt_pp_padsv)
  o->op_ppaddr = lt_pp_padsv_saved;

 PL_ppaddr[OP_PADSV] = lt_pp_padsv_saved;
 lt_pp_padsv_saved   = 0;
}

/* ... Our ck_pad{any,sv} .................................................. */

/* Sadly, the PADSV OPs we are interested in don't trigger the padsv check
 * function, but are instead manually mutated from a PADANY. This is why we set
 * PL_ppaddr[OP_PADSV] in the padany check function so that PADSV OPs will have
 * their pp_ppaddr set to our pp_padsv. PL_ppaddr[OP_PADSV] is then reset at the
 * beginning of every ck_pad{any,sv}. Some unwanted OPs can still call our
 * pp_padsv, but much less than if we would have set PL_ppaddr[OP_PADSV]
 * globally. */

STATIC SV *lt_default_meth = NULL;

STATIC OP *(*lt_old_ck_padany)(pTHX_ OP *) = 0;

STATIC OP *lt_ck_padany(pTHX_ OP *o) {
 HV *stash;
 SV *code;

 lt_pp_padsv_restore(o);

 o = CALL_FPTR(lt_old_ck_padany)(aTHX_ o);

 stash = PL_in_my_stash;
 if (stash && (code = lt_hint())) {
  SV *orig_pkg  = newSVpvn(HvNAME_get(stash), HvNAMELEN_get(stash));
  SV *orig_meth = lt_default_meth;
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
   SvREFCNT_inc(orig_pkg);
  }

  if (!type_meth) {
   type_meth = orig_meth;
   SvREFCNT_inc(orig_meth);
  }

  lt_pp_padsv_save();

  lt_map_store(o, orig_pkg, type_pkg, type_meth, lt_pp_padsv_saved);
 } else {
skip:
  lt_map_delete(o);
 }

 return o;
}

STATIC OP *(*lt_old_ck_padsv)(pTHX_ OP *) = 0;

STATIC OP *lt_ck_padsv(pTHX_ OP *o) {
 lt_pp_padsv_restore(o);

 lt_map_delete(o);

 return CALL_FPTR(lt_old_ck_padsv)(aTHX_ o);
}

STATIC U32 lt_initialized = 0;

/* --- XS ------------------------------------------------------------------ */

MODULE = Lexical::Types      PACKAGE = Lexical::Types

PROTOTYPES: ENABLE

BOOT: 
{                                    
 if (!lt_initialized++) {
  HV *stash;
#if LT_THREADSAFE || LT_WORKAROUND_REQUIRE_PROPAGATION
  MY_CXT_INIT;
  MY_CXT.tbl   = ptable_new();
#endif
#if LT_THREADSAFE
  MY_CXT.owner = aTHX;
#endif

  lt_op_map = ptable_new();
#ifdef USE_ITHREADS
  MUTEX_INIT(&lt_op_map_mutex);
#endif

  lt_default_meth = newSVpvn("TYPEDSCALAR", 11);
  SvREADONLY_on(lt_default_meth);

  PERL_HASH(lt_hash, __PACKAGE__, __PACKAGE_LEN__);

  lt_old_ck_padany    = PL_check[OP_PADANY];
  PL_check[OP_PADANY] = MEMBER_TO_FPTR(lt_ck_padany);
  lt_old_ck_padsv     = PL_check[OP_PADSV];
  PL_check[OP_PADSV]  = MEMBER_TO_FPTR(lt_ck_padsv);

  stash = gv_stashpvn(__PACKAGE__, __PACKAGE_LEN__, 1);
  newCONSTSUB(stash, "LT_THREADSAFE", newSVuv(LT_THREADSAFE));
 }
}

#if LT_THREADSAFE

void
CLONE(...)
PROTOTYPE: DISABLE
PREINIT:
 ptable *t;
 int    *level;
CODE:
 {
  my_cxt_t ud;
  dMY_CXT;
  ud.tbl   = t = ptable_new();
  ud.owner = MY_CXT.owner;
  ptable_walk(MY_CXT.tbl, lt_ptable_hints_clone, &ud);
 }
 {
  MY_CXT_CLONE;
  MY_CXT.tbl   = t;
  MY_CXT.owner = aTHX;
 }
 {
  level = PerlMemShared_malloc(sizeof *level);
  *level = 1;
  LEAVE;
  SAVEDESTRUCTOR_X(lt_thread_cleanup, level);
  ENTER;
 }

#endif

SV *
_tag(SV *value)
PROTOTYPE: $
CODE:
 RETVAL = lt_tag(value);
OUTPUT:
 RETVAL

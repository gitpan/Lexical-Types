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

#ifndef HvNAME_get
# define HvNAME_get(H) HvNAME(H)
#endif

#ifndef HvNAMELEN_get
# define HvNAMELEN_get(H) strlen(HvNAME_get(H))
#endif

/* --- Helpers ------------------------------------------------------------- */

/* ... Hints ............................................................... */

STATIC U32 lt_hash = 0;

STATIC SV *lt_hint(pTHX) {
#define lt_hint() lt_hint(aTHX)
 SV *id;
#if LT_HAS_PERL(5, 10, 0)
 id = Perl_refcounted_he_fetch(aTHX_ PL_curcop->cop_hints_hash,
                                     NULL,
                                     __PACKAGE__, __PACKAGE_LEN__,
                                     0,
                                     lt_hash);
#else
 SV **val = hv_fetch(GvHV(PL_hintgv), __PACKAGE__, __PACKAGE_LEN__, lt_hash);
 if (!val)
  return 0;
 id = *val;
#endif
 return (id && SvOK(id)) ? id : NULL;
}

/* ... op => info map ...................................................... */

#define PTABLE_VAL_FREE(V) PerlMemShared_free(V)

#include "ptable.h"

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

STATIC void lt_map_store(pPTABLE_ const OP *o, SV *orig_pkg, SV *type_pkg, SV *type_meth, OP *(*pp_padsv)(pTHX)) {
#define lt_map_store(O, OP, TP, TM, PP) lt_map_store(aPTABLE_ (O), (OP), (TP), (TM), (PP))
 lt_op_info *oi;

#ifdef USE_ITHREADS
 MUTEX_LOCK(&lt_op_map_mutex);
#endif

 if (!(oi = ptable_fetch(lt_op_map, o))) {
  oi = PerlMemShared_malloc(sizeof *oi);
  ptable_store(lt_op_map, o, oi);
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
 SV *hint;

 lt_pp_padsv_restore(o);

 o = CALL_FPTR(lt_old_ck_padany)(aTHX_ o);

 stash = PL_in_my_stash;
 if (stash && (hint = lt_hint())) {
  SV *orig_pkg  = newSVpvn(HvNAME_get(stash), HvNAMELEN_get(stash));
  SV *orig_meth = lt_default_meth;
  SV *type_pkg  = NULL;
  SV *type_meth = NULL;
  SV *code      = INT2PTR(SV *, SvUVX(hint));

  SvREADONLY_on(orig_pkg);

  if (code) {
   int items;
   dSP;

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
  }

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
 }

skip:
 return o;
}

STATIC OP *(*lt_old_ck_padsv)(pTHX_ OP *) = 0;

STATIC OP *lt_ck_padsv(pTHX_ OP *o) {
 lt_pp_padsv_restore(o);

 return CALL_FPTR(lt_old_ck_padsv)(aTHX_ o);
}

STATIC U32 lt_initialized = 0;

/* --- XS ------------------------------------------------------------------ */

MODULE = Lexical::Types      PACKAGE = Lexical::Types

PROTOTYPES: DISABLE

BOOT: 
{                                    
 if (!lt_initialized++) {
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
 }
}

SV *_tag(SV *ref)
PREINIT:
 SV *ret;
CODE:
 if (SvOK(ref) && SvROK(ref)) {
  SV *sv = SvRV(ref);
  SvREFCNT_inc(sv);
  ret = newSVuv(PTR2UV(sv));
 } else {
  ret = newSVuv(0);
 }
 RETVAL = ret;
OUTPUT:
 RETVAL

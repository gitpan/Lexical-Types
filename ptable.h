/* This file is part of the Lexical-Types Perl module.
 * See http://search.cpan.org/dist/Lexical-Types/ */

/* This is a pointer table implementation essentially copied from the ptr_table
 * implementation in perl's sv.c, except that it has been modified to use memory
 * shared across threads.
 * Copyright goes to the original authors, bug reports to me. */

#ifdef PERL_IMPLICIT_SYS
# define pPTABLE  pTHX
# define pPTABLE_ pTHX_
# define aPTABLE  aTHX
# define aPTABLE_ aTHX_
#else
# define pPTABLE
# define pPTABLE_
# define aPTABLE
# define aPTABLE_
#endif

typedef struct ptable_ent {
 struct ptable_ent *next;
 const void *       key;
 void *             val;
} ptable_ent;

typedef struct ptable {
 ptable_ent **ary;
 UV           max;
 UV           items;
} ptable;

#ifndef PTABLE_VAL_FREE
# define PTABLE_VAL_FREE(V)
#endif

STATIC ptable *ptable_new(pPTABLE) {
#define ptable_new() ptable_new(aPTABLE)
 ptable *t = PerlMemShared_malloc(sizeof *t);
 t->max   = 127;
 t->items = 0;
 t->ary   = PerlMemShared_calloc(t->max + 1, sizeof *t->ary);
 return t;
}

#define PTABLE_HASH(ptr) \
  ((PTR2UV(ptr) >> 3) ^ (PTR2UV(ptr) >> (3 + 7)) ^ (PTR2UV(ptr) >> (3 + 17)))

STATIC ptable_ent *ptable_find(const ptable * const t, const void * const key) {
 ptable_ent *ent;
 const UV hash = PTABLE_HASH(key);

 ent = t->ary[hash & t->max];
 for (; ent; ent = ent->next) {
  if (ent->key == key)
   return ent;
 }

 return NULL;
}

STATIC void *ptable_fetch(const ptable * const t, const void * const key) {
 const ptable_ent *const ent = ptable_find(t, key);

 return ent ? ent->val : NULL;
}

STATIC void ptable_split(pPTABLE_ ptable * const t) {
#define ptable_split(T) ptable_split(aPTABLE_ (T))
 ptable_ent **ary = t->ary;
 const UV oldsize = t->max + 1;
 UV newsize = oldsize * 2;
 UV i;

 ary = PerlMemShared_realloc(ary, newsize * sizeof(*ary));
 Zero(&ary[oldsize], newsize - oldsize, sizeof(*ary));
 t->max = --newsize;
 t->ary = ary;

 for (i = 0; i < oldsize; i++, ary++) {
  ptable_ent **curentp, **entp, *ent;
  if (!*ary)
   continue;
  curentp = ary + oldsize;
  for (entp = ary, ent = *ary; ent; ent = *entp) {
   if ((newsize & PTABLE_HASH(ent->key)) != i) {
    *entp     = ent->next;
    ent->next = *curentp;
    *curentp  = ent;
    continue;
   } else
    entp = &ent->next;
  }
 }
}

STATIC void ptable_store(pPTABLE_ ptable * const t, const void * const key, void * const val) {
#define ptable_store(T, K, V) ptable_store(aPTABLE_ (T), (K), (V))
 ptable_ent *ent = ptable_find(t, key);

 if (ent) {
  void *oldval = ent->val;
  PTABLE_VAL_FREE(oldval);
  ent->val = val;
 } else {
  const UV i = PTABLE_HASH(key) & t->max;
  ent = PerlMemShared_malloc(sizeof *ent);
  ent->key  = key;
  ent->val  = val;
  ent->next = t->ary[i];
  t->ary[i] = ent;
  t->items++;
  if (ent->next && t->items > t->max)
   ptable_split(t);
 }
}

#if 0

STATIC void ptable_clear(pPTABLE_ ptable * const t) {
#define ptable_clear(T) ptable_clear(aPTABLE_ (T))
 if (t && t->items) {
  register ptable_ent ** const array = t->ary;
  UV i = t->max;

  do {
   ptable_ent *entry = array[i];
   while (entry) {
    ptable_ent * const oentry = entry;
    void *val = oentry->val;
    entry = entry->next;
    PTABLE_VAL_FREE(val);
    PerlMemShared_free(entry);
   }
   array[i] = NULL;
  } while (i--);

  t->items = 0;
 }
}

STATIC void ptable_free(pPTABLE_ ptable * const t) {
#define ptable_free(T) ptable_free(aPTABLE_ (T))
 if (!t)
  return;
 ptable_clear(t);
 PerlMemShared_free(t->ary);
 PerlMemShared_free(t);
}

#endif

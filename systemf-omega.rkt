#lang racket

;; System F ω
;; Guannan Wei <guannanwei@outlook.com>

(require rackunit)
(require "share.rkt")

;; Expressions

(struct NumE (n) #:transparent)
(struct BoolE (b) #:transparent)
(struct IdE (id) #:transparent)
(struct PlusE (l r) #:transparent)
(struct MultE (l r) #:transparent)
(struct AppE (fun arg) #:transparent)
(struct LamE (arg arg-type body) #:transparent)
(struct IfE (cnd thn els) #:transparent)

(struct TyLamE (arg arg-kind body) #:transparent)
(struct TyAppE (tyfun tyarg) #:transparent)

;; Types

(struct NumT () #:transparent)
(struct BoolT () #:transparent)
(struct VarT (name) #:transparent)
(struct OpAbsT (arg arg-kind body) #:transparent)
(struct OpAppT (t1 t2) #:transparent)
(struct ArrowT (arg res) #:transparent)
(struct ForallT (name kind tybody) #:transparent)

;; Kinds

(struct StarK () #:transparent)
(struct ArrowK (k1 k2) #:transparent)

;; Values

(struct NumV (n) #:transparent)
(struct BoolV (b) #:transparent)
(struct PolyV (body env) #:transparent)
(struct ClosureV (arg body env) #:transparent)

;; Environment & Type Environment

(struct Binding (name val) #:transparent)
(define lookup (make-lookup 'lookup Binding? Binding-name Binding-val))
(define ext-env cons)

(struct TypeBinding (name type) #:transparent)
(struct KindBinding (name kind) #:transparent)
(define type-lookup (make-lookup 'type-lookup TypeBinding? TypeBinding-name TypeBinding-type))
(define kind-lookup (make-lookup 'kind-lookup KindBinding? KindBinding-name KindBinding-kind))
(define ext-tenv cons)

;; Parser

(define (parse s)
  (match s
    [(? number? x) (NumE x)]
    ['true (BoolE #t)]
    ['false (BoolE #f)]
    [(? symbol? x) (IdE x)]
    [`(+ ,l ,r) (PlusE (parse l) (parse r))]
    [`(* ,l ,r) (MultE (parse l) (parse r))]
    [`(λ ([,var : ,ty]) ,body)
     (LamE var (parse-type ty) (parse body))]
    [`(let ([,var : ,ty ,val]) ,body)
     (AppE (LamE var (parse-type ty) (parse body)) (parse val))]
    [`(if ,cnd ,thn ,els)
     (IfE (parse cnd) (parse thn) (parse els))]
    [`(Λ ([,tvar : ,k]) ,body)
     (TyLamE tvar (parse-kind k) (parse body))]
    [`(Λ [,tvar] ,body) (TyLamE tvar (StarK) (parse body))]
    [`(@ ,tyfun ,tyarg) (TyAppE (parse tyfun) (parse-type tyarg))]
    [`(,fun ,arg) (AppE (parse fun) (parse arg))]
    [else (error 'parse "invalid expression")]))

(define (parse-type t)
  (match t
    ['num (NumT)]
    ['bool (BoolT)]
    [(? symbol? x) (VarT x)]
    [`(Λ ([,tvar : ,k]) ,tbody)
     (OpAbsT tvar (parse-kind k) (parse-type tbody))]
    [`(,tyarg -> ,tyres) (ArrowT (parse-type tyarg) (parse-type tyres))]
    [`(∀ ([,tvar : ,k]) ,t) (ForallT tvar (parse-kind k) (parse-type t))]
    [`(∀ [,tvar] ,t) (ForallT tvar (StarK) (parse-type t))]
    [`(,t1 ,t2) (OpAppT (parse-type t1) (parse-type t2))]
    [else (error 'parse-type "invalid type")]))

(define (parse-kind k)
  (match k
    ['* (StarK)]
    [`(,k1 -> ,k2) (ArrowK (parse-kind k1) (parse-kind k2))]))

;; Fresh Number Generator

(define-values (fresh-n current-n) (counter))

(define (refresh!)
  (define-values (fresh-n^ current-n^) (counter))
  (set! fresh-n fresh-n^)
  (set! current-n current-n^))

;; Type Checker

(define (kind-check t tenv)
  (match t
    [(NumT) (StarK)]
    [(BoolT) (StarK)]
    [(ArrowT arg ret) (StarK)]
    [(VarT name) (kind-lookup name tenv)]
    [(OpAbsT arg arg/k body)
     (ArrowK arg/k (kind-check body (ext-tenv (KindBinding arg arg/k) tenv)))]
    [(OpAppT t1 t2)
     (match (kind-check t1 tenv)
       [(ArrowK k1 k2)
        (if (equal? (kind-check t2 tenv) k1)
            k2
            (error 'kind-check "kinds not agree"))]
       [else (error 'kind-check "not an arrow kind")])]
    [(ForallT tvar k body)
     (match (kind-check body (ext-tenv (KindBinding tvar k) tenv))
       [(StarK) (StarK)]
       [else (error 'kind-check "not a * kind")])]))

(define (free-type-var? n ty)
  (match ty
    [(NumT) #f]
    [(BoolT) #f]
    [(ArrowT a r)
     (or (free-type-var? n a) (free-type-var? n r))]
    [(VarT n^) (equal? n^ n)]
    [(OpAppT t1 t2)
     (or (free-type-var? n t1) (free-type-var? n t2))]
    [(OpAbsT arg arg/k body)
     (if (equal? arg n) #f
         (free-type-var? n body))]
    [(ForallT n^ k body)
     (if (equal? n n^) #f
         (free-type-var? n body))]))

(define (type-subst what for in)
  (match in
    [(NumT) (NumT)]
    [(BoolT) (BoolT)]
    [(ArrowT arg res)
     (ArrowT (type-subst what for arg)
             (type-subst what for res))]
    [(VarT n) (if (equal? what n) for in)]
    [(OpAppT t1 t2)
     (OpAppT (type-subst what for t1)
             (type-subst what for t2))]
    [(OpAbsT arg arg/k body)
     (cond [(equal? arg what) in]
           [(free-type-var? arg for)
            (define new-arg (fresh-n))
            (define new-body (type-subst arg (VarT new-arg) body))
            (type-subst what for (OpAbsT new-arg arg/k new-body))]
           [else (OpAbsT arg arg/k (type-subst what for body))])]
    [(ForallT n k body)
     (cond [(equal? n what) in]
           [(free-type-var? n for)
            (define new-n (fresh-n))
            (define new-body (type-subst n (VarT new-n) body))
            (type-subst what for (ForallT new-n k new-body))]
           [else (ForallT n k (type-subst what for body))])]))

(define (type-apply t)
  (match t
    [(OpAppT t1 t2)
     (match (type-apply t1)
       [(OpAbsT arg arg/k body) (type-subst arg t2 body)]
       [else (error 'type-norm "can not substitute")])]
    [else t]))

(define (type-var-alpha ty)
  (type-var-alpha/helper ty (simple-counter)))

(define (type-var-alpha/helper ty c)
  (match ty
    [(OpAbsT arg arg/k body)
     (define new-n (c))
     (OpAbsT new-n arg/k (type-var-alpha/helper (type-subst arg (VarT new-n) body) c))]
    [(ForallT n k body)
     (define new-n (c))
     (ForallT new-n k (type-var-alpha/helper (type-subst n (VarT new-n) body) c))]
    [(ArrowT t1 t2)
     (ArrowT (type-var-alpha/helper t1 c) (type-var-alpha/helper t2 c))]
    [_ ty]))

(define (type-equal? t1 t2)
  (define (type-equal?/OpAbsT t1 t2)
    (define t1/α (type-var-alpha t1))
    (define t2/α (type-var-alpha t2))
    (match* (t1/α t2/α)
      [((OpAbsT arg1 arg/k1 body1) (OpAbsT arg2 arg/k2 body2))
       (and (equal? arg/k1 arg/k2) (type-equal? body1 body2))]))
  
  (define (type-equal?/ForallT t1 t2)
    (define t1/α (type-var-alpha t1))
    (define t2/α (type-var-alpha t2))
    (match* (t1/α t2/α)
      [((ForallT n1 k1 body1) (ForallT n2 k2 body2))
       (and (equal? k1 k2) (type-equal? body1 body2))]))
  
  (define t1^ (type-apply t1))
  (define t2^ (type-apply t2))
  
  (match* (t1^ t2^)
    [((NumT) (NumT)) #true]
    [((BoolT) (BoolT)) #true]
    [((VarT x) (VarT y)) (equal? x y)]
    [((ArrowT t11 t12) (ArrowT t21 t22))
     (and (type-equal? t11 t21) (type-equal? t12 t22))]
    [((OpAbsT _ _ _) (OpAbsT _ _ _))
     (type-equal?/OpAbsT t1^ t2^)]
    [((ForallT _ _ _) (ForallT _ _ _))
     (type-equal?/ForallT t1^ t2^)]
    [((OpAppT t11 t12) (OpAppT t21 t22))
     (and (type-equal? t11 t21) (type-equal? t12 t22))]
    [(_ _) #false]))

(define (typecheck-nums l r tenv)
  (if (and (type-equal? (NumT) (typecheck l tenv))
           (type-equal? (NumT) (typecheck r tenv)))
      (NumT)
      (type-error "not a number")))

(define (typecheck exp tenv)
  (match exp
    [(NumE n) (NumT)]
    [(BoolE b) (BoolT)]
    [(PlusE l r) (typecheck-nums l r tenv)]
    [(MultE l r) (typecheck-nums l r tenv)]
    [(IdE n) (type-lookup n tenv)]
    [(IfE cnd thn els)
     (if (type-equal? (BoolT) (typecheck cnd tenv))
         (let ([thn-type (typecheck thn tenv)]
               [els-type (typecheck els tenv)])
           (if (type-equal? thn-type els-type)
               thn-type
               (type-error "types of branches not agree")))
         (type-error "not a boolean"))]
    [(LamE arg arg-type body)
     (if (equal? (StarK) (kind-check arg-type tenv))
         (ArrowT arg-type (typecheck body (ext-tenv (TypeBinding arg arg-type) tenv)))
         (error 'kind-check "not a * kind"))]
    [(AppE fun arg)
     (match (type-apply (typecheck fun tenv))
       [(ArrowT atype rtype)
        (if (type-equal? atype (typecheck arg tenv))
            rtype
            (type-error "argument types not agree"))]
       [_ (type-error fun "function")])]
    [(TyLamE n k body)
     (ForallT n k (typecheck body (ext-tenv (KindBinding n k) tenv)))]
    [(TyAppE tyfun tyarg)
     (define arg/k (kind-check tyarg tenv))
     (match (type-apply (typecheck tyfun tenv))
       [(ForallT n k body)
        (if (equal? arg/k k) (type-subst n tyarg body)
            (error 'kind-check "kinds not agree"))]
       [else (type-error tyfun "polymorphic function")])]))

;; Interpreter

(define (interp expr env)
  (match expr
    [(IdE x) (lookup x env)]
    [(NumE n) (NumV n)]
    [(BoolE b) (BoolV b)]
    [(PlusE l r) (NumV (+ (NumV-n (interp l env))
                          (NumV-n (interp r env))))]
    [(MultE l r) (NumV (* (NumV-n (interp l env))
                          (NumV-n (interp r env))))]
    [(LamE arg at body) (ClosureV arg body env)]
    [(IfE cnd thn els)
     (match (interp cnd env)
       [(BoolV #t) (interp thn env)]
       [(BoolV #f) (interp els env)])]
    [(AppE fun arg)
     (match (interp fun env)
       [(ClosureV n body env*)
        (interp body (ext-env (Binding n (interp arg env)) env*))])]
    [(TyLamE n k body) (PolyV body env)]
    [(TyAppE tyfun tyarg)
     (match (interp tyfun env)
       [(PolyV body env*) (interp body env*)])]))

(define mt-env empty)
(define mt-tenv empty)

(define (run prog)
  (refresh!)
  (define prog* (parse prog))
  (typecheck prog* mt-tenv)
  (interp prog* mt-env))

;; Tests

(module+ test
  (check-equal? (run '1) (NumV 1))
  (check-equal? (run '{λ {[x : num]} x})
                (ClosureV 'x (IdE 'x) '()))
  (check-equal? (run '{{λ {[x : num]} {+ x x}} 3})
                (NumV 6))
  (check-equal? (run '{let {[double : {num -> num}
                                    {λ {[x : num]} {+ x x}}]}
                        {double 3}})
                (NumV 6))
  (check-equal? (run '{{if true
                           {λ {[x : num]} {+ x 1}}
                           {λ {[x : num]} {+ x 2}}}
                       3})
                (NumV 4))

  (check-equal? (type-subst 'z (NumT)
                            (parse-type '{Λ {[x : *]} {Λ {[y : *]} {x -> {z -> y}}}}))
                (OpAbsT 'x (StarK)
                        (OpAbsT 'y (StarK) (ArrowT (VarT 'x) (ArrowT (NumT) (VarT 'y))))))

  (check-true (type-equal? (parse-type '{{Λ {[x : *]} {x -> x}} num})
                           (parse-type '{{Λ {[y : *]} {y -> y}} num})))

  (check-true (type-equal? (parse-type '{{Λ {[x : *]} {x -> x}} num})
                           (parse-type '{num -> num})))

  (check-equal? (typecheck (parse '{{λ {[id : {{Λ {[x : *]} {x -> x}} num}]}
                                      {+ 4 {id 3}}}
                                    {λ {[x : num]} x}})
                           empty)
                (NumT))

  (check-equal? (run '{{λ {[id : {{Λ {[x : *]} {x -> x}} num}]}
                         {+ 4 {id 3}}}
                       {λ {[x : num]} x}})
                (NumV 7))

  (check-equal? (run '{let {[plus : {{{Λ {[x : *]}
                                         {Λ {[y : *]}
                                            {x -> {y -> x}}}}
                                      num} num}
                                  {λ {[x : num]}
                                    {λ {[y : num]}
                                      {+ x y}}}]}
                        {{plus 1} 2}})
                (NumV 3))
  ;;;

  (check-equal? (typecheck
                 (parse '{let {[f : {∀ {a} {a -> {∀ {b} {{a -> b} -> b}}}}
                                  [Λ [a] {λ {[x : a]}
                                           [Λ [b] {λ {[g : {a -> b}]} {g x}}]}]]}
                           {[@ {[@ f num] 3} bool] {λ {[x : num]} true}}})
                 mt-tenv)
                (BoolT))

  (check-equal? (run '{let {[f : {∀ {a} {a -> {∀ {b} {{a -> b} -> b}}}}
                               [Λ [a] {λ {[x : a]}
                                        [Λ [b] {λ {[g : {a -> b}]} {g x}}]}]]}
                        {[@ {[@ f num] 3} bool] {λ {[x : num]} true}}})
                (BoolV #t))

  ; Boolean Encodings
  
  (define Bool '{∀ {[a : *]} {a -> {a -> a}}})
  (define True '{Λ {[a : *]} {λ {[x : a]} {λ {[y : a]} x}}})
  (define False '{Λ {[a : *]} {λ {[x : a]} {λ {[y : a]} y}}})
  (define And `{λ {[x : ,Bool]} {λ {[y : ,Bool]} {{[@ x ,Bool] y} ,False}}})
  (define Bool->Num `{λ {[x : ,Bool]} {{[@ x num] 1} 0}})

  (check-equal? (run `{let {[t : ,Bool ,True]}
                        {let {[f : ,Bool ,False]}
                          {let {[and : {,Bool -> {,Bool -> ,Bool}} ,And]}
                            {,Bool->Num {{and t} f}}}}})
                (NumV 0))

  (check-equal? (run `{let {[t : ,Bool ,True]}
                        {let {[f : ,Bool ,False]}
                          {let {[and : {,Bool -> {,Bool -> ,Bool}} ,And]}
                            {,Bool->Num {{and t} t}}}}})
                (NumV 1))

  ;; Pair Encodings

  (define PairT '{Λ {[A : *]} {Λ {[B : *]} {∀ {[C : *]} {{A -> {B -> C}} -> C}}}})
  (define make-pair '{Λ {[A : *]} {Λ {[B : *]}
                                     {λ {[x : A]} {λ {[y : B]} {Λ {[C : *]}
                                                                  {λ {[k : {A -> {B -> C}}]}
                                                                    {{k x} y}}}}}}})
  
  (define fst `{Λ {[A : *]} {Λ {[B : *]} {λ {[p : [[,PairT A] B]]}
                                           {[@ p A] {λ {[x : A]} {λ {[y : B]} x}}}}}})
  (define snd `{Λ {[A : *]} {Λ {[B : *]} {λ {[p : [[,PairT A] B]]}
                                           {[@ p B] {λ {[x : A]} {λ {[y : B]} y}}}}}})

  (define PairT-num/bool `[[,PairT num] bool])

  (define make-pair-num/bool `[@ [@ ,make-pair num] bool])
  (define fst-num/bool `[@ [@ ,fst num] bool])
  (define snd-num/bool `[@ [@ ,snd num] bool])
  
  (check-equal? (typecheck (parse `{{,make-pair-num/bool 1} true}) empty)
                (type-apply (parse-type PairT-num/bool)))
  
  (check-equal? (typecheck (parse `{let {[p : ,PairT-num/bool
                                            {{,make-pair-num/bool 1} true}]}
                                     {,fst-num/bool p}}) empty)
                (NumT))
  
  (check-equal? (typecheck (parse `{let {[p : ,PairT-num/bool
                                            {{,make-pair-num/bool 1} true}]}
                                     {,snd-num/bool p}}) empty)
                (BoolT))

  (check-equal? (run `{let {[p : ,PairT-num/bool
                               {{,make-pair-num/bool 1} true}]}
                        {,snd-num/bool p}})
                (BoolV #t))

  ;; Equal under alpha renaming
  (check-equal? (typecheck (parse '{if true
                                       {Λ {[A : *]} {λ {[x : A]} x}}
                                       {Λ {[B : *]} {λ {[y : B]} y}}})
                           empty)
                (ForallT 'A (StarK) (ArrowT (VarT 'A) (VarT 'A))))
  )

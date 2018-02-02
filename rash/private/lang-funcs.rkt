#lang racket/base

(provide
 rash
 rash/wired
 run-pipeline
 run-pipeline/logic
 cd

 (all-from-out shell/pipeline-macro)
 (all-from-out "linea/line-macro.rkt")

 make-rash-reader-submodule
 define-rash-module-begin
 (for-syntax
  make-rash-transformer
  ))

(module+ experimental
  (provide (for-syntax rash-template-escaper)))

(module+ for-repl
  (provide
   rash-set-defaults
   run-pipeline
   run-pipeline/logic
   ))


(require
 (rename-in shell/pipeline-macro
            [run-pipeline run-pipeline/no-line-macro]
            [run-pipeline/logic run-pipeline/logic/no-line-macro])
 racket/splicing
 racket/string
 racket/port
 "cd.rkt"
 "linea/line-macro.rkt"
 "linea/line-parse.rkt"
 "linea/read.rkt"
 (only-in shell/private/pipeline-macro-parse rash-set-defaults)
 syntax/parse
 syntax/wrap-modbeg

 (for-syntax
  syntax/wrap-modbeg
  syntax/keyword
  racket/base
  syntax/parse
  "linea/read.rkt"
  shell/private/misc-utils

  (for-syntax
   "linea/read.rkt"
   syntax/wrap-modbeg
   racket/base
   syntax/parse
   syntax/keyword
   "template-escape-detect.rkt"
   shell/private/misc-utils
   )))

(define-line-macro run-pipeline
  (λ (stx)
    (syntax-parse stx
      [(_ arg ...)
       #'(run-pipeline/no-line-macro arg ...)])))
(define-line-macro run-pipeline/logic
  (λ (stx)
    (syntax-parse stx
      [(_ arg ...)
       #'(run-pipeline/logic/no-line-macro arg ...)])))

(define default-output-port-transformer (λ (p) (string-trim (port->string p))))

(module keyword-table racket/base
  (provide rash-keyword-table)
  (require syntax/keyword)
  (define rash-keyword-table
    (list (list '#:in check-expression)
          (list '#:out check-expression)
          (list '#:err check-expression)
          (list '#:default-starter check-expression)
          (list '#:default-line-macro check-expression))))
(require (for-syntax (submod "." keyword-table))
         (for-meta 2 (submod "." keyword-table)))

(define-syntax (rash-expressions-begin stx)
  (syntax-parse stx
    [(_ (input output err-output default-starter line-macro) e ...+)
     #`(splicing-let ([in-eval input]
                      [out-eval output]
                      [err-eval err-output])
         (splicing-syntax-parameterize ([default-pipeline-starter default-starter]
                                        [default-line-macro line-macro])
           (rash-set-defaults
            (in-eval out-eval err-eval)
            (linea-line-parse e ...))))]))


#|
TODO

The define-rash-module-begin and make-reader-submodule stuff is really an
intermediate step to better configurability.

I want a form to easily define a new #lang based on rash with custom options for
the defaults and the reader.  Something like this:

```
#lang racket/base
(require rash)
(provide (except-out (all-from-out racket/base)
                     #%module-begin)
         (all-from-out rash)
         (except-out (all-defined-out)
                     my-mb)
         (rename-out [my-mb #%module-begin])
         )
(rash-hash-lang-setup
 #:module-begin-name my-mb
 #:default-starter =object-pipe=
 #:rash-readtable (modify-readtable-somehow basic-rash-readtable)
 ...
 )
```

And then be able to use the module path for that module as a #lang.

Also it might be nice for #lang rash to take arguments that affect it somehow.
But how can it be done in a way that let those arguments affect the reader?
|#

(define-syntax (make-rash-reader-submodule stx)
  (syntax-parse stx
    [(_ this-module-path)
     #'(begin
         (module reader syntax/module-reader
           this-module-path
           #:read-syntax linea-read-syntax
           #:read linea-read
           (require rash/private/linea/read)))]))

(define-syntax (identity-macro stx)
  (syntax-parse stx
    [(_ e) #'e]))

(define-syntax (define-rash-module-begin stx)
  (syntax-parse stx
    [(_ rmb-name make-mb-arg ...)
     (define-values (tab rest-stx)
       (parse-keyword-options #'(make-mb-arg ...)
                              (list*
                               (list '#:this-module-path check-expression)
                               (list '#:top-level-wrap check-expression)
                               rash-keyword-table)
                              #:context stx
                              #:no-duplicates? #t))
     (syntax-parse rest-stx
       [() (void)]
       [else (raise-syntax-error 'make-rash-module-begin-transformer "unexpected arguments" rest-stx)])
     (with-syntax ([this-mod-path (opref tab '#:this-module-path
                                         #'(raise-syntax-error
                                            'make-rash-module-begin-transformer
                                            "expected #:this-module-path argument."))]
                   [top-level-wrap (opref tab '#:top-level-wrap #'identity-macro)]
                   [mk-input (opref tab '#:in #'(current-input-port))]
                   [mk-output (opref tab '#:out #'(current-output-port))]
                   [mk-err-output (opref tab '#:err #'(current-error-port))]
                   [mk-default-starter (opref tab '#:default-starter
                                              #'=unix-pipe=)]
                   [mk-default-line-macro (opref tab '#:default-line-macro
                                                 #'run-pipeline)]
                   [wrap-modbeg-name (datum->syntax stx (gensym
                                                         'wrapping-modbeg-for-rash))])
       #'(begin
           (define-syntax wrap-modbeg-name
             (make-wrapping-module-begin #'top-level-wrap))
           (define-syntax rmb-name
             (syntax-parser
               [(_ arg (... ...))
                #'(wrap-modbeg-name
                   (module configure-runtime racket/base
                     (require rash/private/linea/read
                              rash/private/lang-funcs
                              this-mod-path)
                     (current-read-interaction
                      (λ (src in)
                        (let ([stx (linea-read-syntax src in)])
                          (if (eof-object? stx)
                              stx
                              (syntax-parse stx
                                [e #'(rash-expressions-begin
                                      (mk-input
                                       mk-output
                                       mk-err-output
                                       #'mk-default-starter
                                       #'mk-default-line-macro)
                                      e)]))))))
                   (rash-expressions-begin (mk-input
                                            mk-output
                                            mk-err-output
                                            #'mk-default-starter
                                            #'mk-default-line-macro)
                                           arg (... ...)))]))))]))

(begin-for-syntax
  (define-syntax (make-rash-transformer stx)
    (syntax-parse stx
      [(_ make-transformer-arg ...)
       (define-values (tab rest-stx)
         (parse-keyword-options #'(make-transformer-arg ...)
                                rash-keyword-table
                                #:context stx
                                #:no-duplicates? #t))
       (syntax-parse rest-stx
         [() (void)]
         [else (raise-syntax-error
                'make-rash-transformer
                "unexpected arguments"
                rest-stx)])
       (with-syntax ([mk-input (opref tab '#:in #'(open-input-string ""))]
                     [mk-output (opref tab '#:out #'default-output-port-transformer)]
                     [mk-err-output (opref tab '#:err #''string-port)]
                     ;; TODO - make it possible for these to inherit
                     [mk-default-starter (opref tab '#:default-starter
                                                #'=unix-pipe=)]
                     [mk-line-macro (opref tab '#:default-line-macro
                                           #'run-pipeline)])
         #'(λ (stx)
             (syntax-parse stx
               [(rash tx-arg (... ...))
                (define-values (tab rest-stx)
                  (parse-keyword-options #'(tx-arg (... ...))
                                         rash-keyword-table
                                         #:context stx
                                         #:no-duplicates? #t))

                (with-syntax ([(parsed-rash-code (... ...))
                               (linea-stx-strs->stx rest-stx)]
                              [input (opref tab '#:in #'mk-input)]
                              [output (opref tab '#:out #'mk-output)]
                              [err-output (opref tab '#:err #'mk-err-output)]
                              [default-starter (opref tab '#:default-starter
                                                      #'#'mk-default-starter)]
                              [line-macro (opref tab '#:default-line-macro
                                                 #'#'mk-line-macro)])
                  #'(rash-expressions-begin (input output err-output
                                                   default-starter
                                                   line-macro)
                                            parsed-rash-code (... ...)))])))]))
  )

(define-syntax rash
  (make-rash-transformer))
(define-syntax rash/wired
  (make-rash-transformer #:in (current-input-port)
                         #:out (current-output-port)
                         #:err (current-error-port)))

(begin-for-syntax
  (define-syntax rash-template-escaper
    (template-escape-struct
     (λ (stx)
       (syntax-parse stx
         [(_ arg ...)
          (with-syntax ([(parsed-rash-code ...) (linea-stx-strs->stx #'(arg ...))])
            #'(rash-expressions-begin
               ((open-input-string "")
                default-output-port-transformer
                'string-port)
               parsed-rash-code ...))])))))


;;; -*- Package: user -*-
(in-package "USER")
;;;----------------------------------------------------------------------
;;; Compilation infrastructure.

;; Given an object, return non-nil IFF it could possibly be an
;; infix-operator statement.
(defun infix-form? (form)
  (and (listp form)
       (>= (length form) 2)
       (symbolp (second form))
       (get (second form) 'is-infix)))

;; Given a form, get it into the canonical form where the operator is
;; first.  NOTE: This function used to be named just "canonicalize",
;; but that is a reserved name in the "EXT" package.  Changed 9/18/18.
(defun canonicalize-form (form)
  (if (infix-form? form)
      `(,(second form) ,(first form) . ,(cddr form))
    form))

;; Given an object, if it's an operator (construct) symbol, return
;; its definition.
(defun definition (operator)
  (and (symbolp operator)
       (get operator 'construct-definition)))

;; Given an operator (construct symbol), return the opposite operator.
;; (Which will undo the effect of the given operator.)
(defun opposite (operator)
  (get operator 'opposite))

;; Given an object, return non-NIL iff it may potentially be a
;; single form statement (not a label atom) with a definition.
(defun statement? (form)
  (and (listp form)
       (not (null form))
       (or (definition (car form))
	   (infix-form? form))))

;; Guess whether an object may be a list of statements/primitives.
(defun list-of-statements? (obj)
  (and (listp obj)
       (not (statement? obj))
       (not (null obj))
       (statement? (car obj))))

;; DEFCONSTRUCT - Define how a particular construct is to be compiled.
;; Given a construct name symbol CNAME, lambda list LAMBDA-LIST, and body
;; statements BODY, define CNAME to be a reversible language construct with
;; structure given by LAMBDA-LIST and compilation generated by the BODY.
;; During compilation the BODY gets executed with the variables mentioned
;; in the LAMBDA-LIST bound to corresponding parts of the item to be
;; compiled, and with the variable ENV bound to the variable-location
;; environment in effect at the start of the statement.  The body should
;; return 2 values: the first is a list of statements to which this
;; statement is equivalent.  The second value indicates the environment in
;; effect after the given statement(s).  It may be NIL meaning that the
;; source as a high-level statement does not affect the environment after
;; the statement, although the compiled lower-level statements might.

(defmacro defconstruct (cname lambda-list &body body)
  (let ((opposite
	 (if (eq (car body) :opposite)
	     (prog1
	       (cadr body)
	       (setf body (cddr body)))
	   cname)))
    `(setf (get ',cname 'opposite) ',opposite
	   (get ',cname 'construct-definition)
	   #'(lambda (args env)
	       (let ((form (cons ',cname args)))
		 (destructuring-bind ,lambda-list args
		   . ,body))))))

(defmacro definfix ((leftarg opname &rest rightargs) &body body)
  `(progn
     (defconstruct ,opname (,leftarg . ,rightargs)
       . ,body)
     (true! (get ',opname 'is-infix))))


;;::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
;; RCOMP-ITERATIVE-BROKEN - An iterative (as opposed to recursive) version of
;; RCOMP.  Implemented 8/4/01 because RCOMP and RCOMP-DEBUG seem to be
;; seg-faulting on large programs, for reasons inexplicable other than
;; by assuming that CLISP is running out of stack space or something.
;; (8/4) - Doesn't work, and not debugged yet.
;;::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
(defun rcomp-iterative-broken (source &key env debug)
  ;; Default to starting with the empty environment.
  (when (null env) (setf env (empty-env)))
  (let ((orig-source source)
	(compiled '()))
    ;; Keep processing until no source code is left.
    (loop
      (if (null source) (return))
      ;; Make sure that the source code (in case it's a single
      ;; statement) is in the canonical prefix (rather than infix)
      ;; form.
      (setf source (canonicalize-form source))
      (cond
       ;; If the source is a single statement, replace it with its
       ;; expansion.
       ((statement? source)
	;; Source is a single non-label statement with a definition.
	(let ((def (definition (first source))))
	  (mvbind (compiled endenv)
		  ;; Perform a single step of compilation.
		  (funcall def (cdr source) env)
	     ;; Now, the source is the result of that step, and
	     ;; the environment is changed.  Keep going.
	     (setf source compiled)
	     (mvbind (recomp reenv)
		     ;; Try compiling it further.
		     (rcomp-iterative compiled :env env :debug debug)
		;; The compiled code is the result of that while process.
		(setf compiled recomp)
		;; It is important to return the environment resulting
		;; from the OUTER compilation step, in case the inner
		;; one doesn't return anything useful.
		(setf env (or endenv reenv))
		;; Make sure to set the source to NIL so we stop here.
		(setf source nil)
		))))
       ((form-list? source)
	;; Source is a list of statements.  Let's go through them iteratively.
	(mvbind (firstcomp firstendenv)
		;; Compile the first statement all the way down to the assembly.
		(rcomp-iterative (first source) :env env :debug debug)
	    ;; Add the compiled code obtained to COMPILED, and update
	    ;; the environment, and change SOURCE to its former CDR.
	    (setf compiled (append compiled firstcomp))
	    (setf env firstendenv)
	    (pop source)))
       (t
	;; In all other cases just compile the source to itself
	;; and leave the environment unchanged.  This is an uncompilable
	;; or assembly language statement that should be included in the
	;; compiled output.
	(setf compiled source)
	(setf source nil)
	))
      (when debug
	(format t "~&Original source:~%")
	(myprint orig-source)
	(format t "~&Compiled so far:~%")
	(myprint compiled)
	(format t "~&Source remaining:~%")
	(myprint source)
	(format t "~&Environment: ~:w" env))
      )
    (values compiled env)))

;;::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
;; RCOMP - Given a statement or a list of statements to compile and an
;; optional initial environment (which defaults to the empty
;; environment), return an equivalent list of compiled statements and
;; the environment in effect after them.
;;
;; (8/4/01) - This version,
;; being recursive, seems to run out of memory easily.

(defun rcomp (source &optional startenv)
  (when (null startenv) (setf startenv (empty-env)))
  (setf source (canonicalize-form source))
  (cond
   ((null source)
    (values source startenv))
   ((statement? source)
    ;; Source is a single non-label statement with a definition.
    (let ((def (definition (first source))))
      (mvbind (compiled endenv)
	      ;; Compile it once.
	      (funcall def (cdr source) startenv)
	 (mvbind (recomp reenv)
		 ;; Try compiling it further.
		 (rcomp compiled startenv)
	    (values recomp
		    (or endenv reenv))))))
   ((form-list? source)
    ;; Source is a list of statements.
    (mvbind (firstcomp firstendenv)
	    ;; Compile first statement.
	    (rcomp (first source) startenv)
       (mvbind (restcomp restendenv)
	       ;; Compile remaining statements in environment from
	       ;; first statement.
	       (rcomp (rest source) firstendenv)
	  (values (if (listp firstcomp)
		      (append firstcomp restcomp)
		    (cons firstcomp restcomp))
		  restendenv))))
   (t
    ;; In all other cases just compile the source to itself
    ;; and leave the environment unchanged.
    (values (list source) startenv))))

;(defparameter *annotate* '(defword defarray defsub defmain let if call rcall for exregstack swapregs movereg))
;(defparameter *annotate* '(defsub defmain if call rcall for exregstack swapregs movereg))
;(defparameter *annotate* '(defsub defmain if call rcall for relocate vacate))
;(defparameter *annotate* '(defsub defmain if call rcall for))
(defparameter *annotate* '())

;; 
;; This version of RCOMP, for debugging purposes, prints out the entire
;; state of the partially-compiled program after each individual code
;; transformation.
;; 
;; WHOLE represents the entire current state of the compilation,
;; represented as a cons cell whose CDR is the current partially-compiled
;; source, which MUST be a LIST of statements, not a single statement.
;; POINTER is a pointer to the cons cell whose CDR is the part of the
;; source that remains to be compiled.  In general, the CAR of this CDR
;; will be an ENV statement giving the current environment.
;; 
(defun rcomp-repl (whole &optional (pointer whole) (debug nil))
  (loop
    (block myblock
      (when debug
	  (myprint (cdr whole))
             #|  (if (eq (caadr pointer) 'env)
                 (cddr pointer)
                 (cdr pointer))) |#	;Print thuh whole shebang.
        (format t "~&---------------------------------------------------------------------- ")
        ;; (clear-input) (finish-output) ;These don't seem to work right.
        ;; (read-line)
      )
      (let ((source (cdr pointer))  ;Remaining source to compile.
		startenv)
        
        (if (and (listp source)           ;List of statements.
                 (listp (car source))     ;Non-label statement.
                 (eq (caar source) 'env)) ;Special (ENV <env>) statement.
          (setf startenv (cadar source))  ;Get the <env>
          (progn 
            ;; Invent an ENV statement and insert it.
            (if debug (format t "~&Default environment.~%"))
            (setf startenv (empty-env))
            (setf (cdr pointer)	;Alter our object as follows.
                  `((env ,startenv) . ,source) )
            (if debug (myprint (cdr whole)) ) ;(cddr pointer)))
          )
        )
        
        ;; Now STARTENV is the current env, and current source obj is just
	  ;; after the initial env statement.
        (setf source (cddr pointer))
        
        ;; If no statements left to compile, we're done.
        (when (null source)
          (return-from rcomp-repl whole))
        
        (let ((form (car source)))
          ;; From here on we approximately mirror structure of RCOMP.
          
          ;; If first form is an infix form, canonicalize it.
          (when (infix-form? form)
            (if debug (format t "~%Canonicalizing: ~s~%" form))
            (setf form (canonicalize-form form) (car source) form)
            (if debug (format t "canonicalized form: ~s~%" form))
            ;(myprint (cdr whole))
          )
          
          ;; If first item is label, do nothing with it.
          (when (atom form)
            (if debug (format t "~&Label.~%"))
            (setf (cdr pointer)
                  `(,form
                   (env ,startenv)
                   . ,(cdr source)))
            (setf pointer (cdr pointer))
            (return-from myblock))
          
          ;; Otherwise, first item is a non-label STATEMENT.
          (let ((first (first form))
                def)
            
            (cond
             ((symbolp first)
              ;; Assume source code is a single statement, FIRST is the symbol
              ;; naming the statement type, for dispatching.
               
              (setq def (definition first))  ;get construct definition
                
              (when (eq first 'env)
                (if debug (format t "~&Environment override.~%"))
                (setf (cdr pointer) source)
                (return-from myblock) )

              (when (eq first 'defsub)
                (format t "~&Compiling ~s...~%" (second form)) )

              (when (member first *annotate*)
                ;; Annote the compiler output with the source statement.
                (setf (cdr pointer)
                      `((source ,form)
                       . ,(cdr pointer)))
                (setf pointer (cdr pointer)) )
              
              (when (null def)
                ;; No definition for this statement.  Assume it's a final
                ;; assembly instruction and doesn't change the environment.
                (if debug (format t "~&Final.~%"))
                (setf (cdr pointer)
                  `(,form
                   (env ,startenv)
                   . ,(cdr source)))
                (setf pointer (cdr pointer))
                (return-from myblock) )
              
              ;; There is a definition for the statement
              (mvbind (compiled endenv)
                ;; Call the transformer function.
                (funcall def (cdr form) startenv)
                      
                ;; Insert result.
                (if debug (format t "~&Expand ~s.~%" first))
                (if (and endenv (null compiled))
                  (setf (cdr pointer)
                        `((env ,endenv)
                         . ,(cdr source)))
                  (setf (cddr pointer)
                        (if endenv
                          `(,@(if compiled
                                (if (not (form-list? compiled))
                                  (list compiled)
                                  compiled))
                            (env ,endenv)
                            . ,(cdr source))
  
                          `(,@(if compiled
                                (if (not (form-list? compiled))
                                  (list compiled)
                                  compiled))
                            . ,(cdr source)))) )
                      
                ;; Try compiling same thing again.
                (return-from myblock) ))
             
             ;; The first item isn't a symbol so assume it's a statement
             ;; and treat the form as a list of statements.
             (t
              (setf source
                    (append form (cdr source))
                    (cddr pointer) source)
              (if debug (format t "~&Insert statement list.~%"))
              (return-from myblock) )))))))
)
  
;; RCOMP-ITERATIVE
(defun rcomp-iterative (source &key debug)
  (let ((whole (cons nil (list source)))) ; see RCOMP-REPL for explanation of WHOLE
    (rcomp-repl whole whole debug) ;; 2nd whole is pointer
    ))

;; The user-level compiler-debugging routine.
(defun rcomp-debug (source)
  (rcomp-iterative source :debug t))

(defun rcd (source)
  (rcomp-debug source))

;; non-nil iff obj could be a list of forms (not incl. label syms)
(defun form-list? (obj)
  (and (listp obj)
       (not (and (car obj) (symbolp (car obj))))
       (not (and (cadr obj) (symbolp (cadr obj))))))

;; Expand the source code to its compilation once, but not
;; recursively.  This is for debugging.
(defun expand1 (source &optional env)
  (let ((def (get (first source) 'construct-definition)))
    (if (null def)
	(values (list source) env)
      (funcall def (cdr source) env))))


;; For testing.
;(defun myprint (code &optional pointer)
(defun myprint (code &optional (ostream t))
  
  (cond ((not (listp code))
         (pprint code)
         (values) ))
  
  ;write header for simulator
  (if (not (eq ostream t))
      (format ostream "~&;; pendulum pal file~%") )
  
  (format ostream "~%")

  (dolist (s code)
    (cond
       ;Interpret atoms as labels
       ((atom s)  
        (format ostream "~s:~15T" s) )
     
       ;Print source code as comment if included
       ((and (symbolp (car s))
             (eq (car s) 'source) )
        (format ostream "~32T;;; ~w~%" (cadr s)) )

       ;Print regular instructions
       ((and (symbolp (car s))
             (not (get (car s) 'construct-definition))
             (not (eq (car s) 'env))
             (not (and (symbolp (cadr s))
                       (get (cadr s) 'construct-definition) )))
        (format ostream "~16T")
        (dolist (w s)
          (if (register? w)
              (format ostream "$~s " (cadr w))
              (format ostream "~:w " w) ))
        (format ostream "~%") )

       (t
        (format ostream "~16T~<~:W~:>~%" s) )))

  (format ostream "~&~%")
)


(defun rc (source &key debug env) ;; ENV is currently ignored.
  (mvbind (prog newenv)
    (if debug
      (rcomp-iterative source :debug t)
      (rcomp-iterative source) )

    (values prog)
  )
)


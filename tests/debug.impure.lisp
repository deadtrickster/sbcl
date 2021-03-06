;;;; This file is for testing debugging functionality, using
;;;; test machinery which might have side effects (e.g.
;;;; executing DEFUN).

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; While most of SBCL is derived from the CMU CL system, the test
;;;; files (like this one) were written from scratch after the fork
;;;; from CMU CL.
;;;;
;;;; This software is in the public domain and is provided with
;;;; absolutely no warranty. See the COPYING and CREDITS files for
;;;; more information.

(cl:in-package :cl-user)

;;; The debugger doesn't have any native knowledge of the interpreter
(when (eq sb-ext:*evaluator-mode* :interpret)
  (sb-ext:exit :code 104))


;;;; Check that we get debug arglists right.

(defvar *p* (namestring *load-truename*))

;;; FIXME: This should use some get-argslist like functionality that
;;; we actually export.
;;;
;;; Return the debug arglist of the function object FUN as a list, or
;;; punt with :UNKNOWN.
(defun get-arglist (fun)
  (declare (type function fun))
  ;; The Lisp-level type FUNCTION can conceal a multitude of sins..
  (case (sb-kernel:widetag-of fun)
    (#.sb-vm:simple-fun-header-widetag
      (sb-kernel:%simple-fun-arglist fun))
    (#.sb-vm:closure-header-widetag (get-arglist
                                     (sb-kernel:%closure-fun fun)))
    ;; In code/describe.lisp, ll. 227 (%describe-fun), we use a scheme
    ;; like above, and it seems to work. -- MNA 2001-06-12
    ;;
    ;; (There might be other cases with arglist info also.
    ;; SIMPLE-FUN-HEADER-WIDETAG and CLOSURE-HEADER-WIDETAG just
    ;; happen to be the two case that I had my nose rubbed in when
    ;; debugging a GC problem caused by applying %SIMPLE-FUN-ARGLIST to
    ;; a closure. -- WHN 2001-06-05)
    (t
     #+sb-eval
     (if (typep fun 'sb-eval::interpreted-function)
         (sb-eval::interpreted-function-lambda-list fun)
         :unknown)
     #-sb-eval
     :unknown)))

(defun zoop (zeep &key beep)
  blurp)
(assert (equal (get-arglist #'zoop) '(zeep &key beep)))

;;; Check some predefined functions too.
;;;
;;; (We don't know exactly what the arguments are, e.g. the first
;;; argument of PRINT might be SB-IMPL::OBJECT or SB-KERNEL::OBJ or
;;; whatever. But we do know the general structure that a correct
;;; answer should have, so we can safely do a lot of checks.)
(with-test (:name :predefined-functions-1)
  (destructuring-bind (object-sym &optional-sym stream-sym) (get-arglist #'print)
    (assert (symbolp object-sym))
    (assert (eql &optional-sym '&optional))
    (assert (symbolp stream-sym))))
(with-test (:name :predefined-functions-2)
  (destructuring-bind (dest-sym control-sym &rest-sym format-args-sym)
      (get-arglist #'format)
    (assert (symbolp dest-sym))
    (assert (symbolp control-sym))
    (assert (eql &rest-sym '&rest))
    (assert (symbolp format-args-sym))))

;;; Check for backtraces generally being correct.  Ensure that the
;;; actual backtrace finishes (doesn't signal any errors on its own),
;;; and that it contains the frames we expect, doesn't contain any
;;; "bogus stack frame"s, and contains the appropriate toplevel call
;;; and hasn't been cut off anywhere.
(defun verify-backtrace (test-function frame-specs &key (allow-stunted nil))
  (labels ((args-equal (want real)
             (cond ((eq '&rest (car want))
                    t)
                   ((endp want)
                    (endp real))
                   ((or (eq '? (car want)) (equal (car want) (car real)))
                    (args-equal (cdr want) (cdr real)))
                   (t
                    nil))))
    (let ((result nil))
      (block outer-handler
        (handler-bind
            ((error (lambda (condition)
                      ;; find the part of the backtrace we're interested in
                      (let* ((full-backtrace (sb-debug:backtrace-as-list))
                             (backtrace (member (caar frame-specs) full-backtrace
                                                :key #'car
                                                :test #'equal)))

                        (setf result condition)

                        (unless backtrace
                          (format t "~&//~S not in backtrace:~%   ~S~%"
                                  (caar frame-specs)
                                  full-backtrace)
                          (setf result nil))
                        ;; check that we have all the frames we wanted
                        (mapcar
                         (lambda (spec frame)
                           (unless (or (not spec)
                                       (and (equal (car spec) (car frame))
                                            (args-equal (cdr spec)
                                                        (cdr frame))))
                             (print (list :wanted spec :got frame))
                             (setf result nil)))
                         frame-specs
                         backtrace)

                        ;; Make sure the backtrace isn't stunted in
                        ;; any way.  (Depends on running in the main
                        ;; thread.) FIXME: On Windows we get two
                        ;; extra foreign frames below regular frames.
                        (unless (find '(sb-impl::toplevel-init) backtrace
                                      :test #'equal)
                          (print (list :backtrace-stunted backtrace))
                          (setf result nil))
                        (return-from outer-handler)))))
          (funcall test-function)))
      result)))

(defvar *undefined-function-frame*
  ;; bug 353
  '("undefined function"))

;;; Test for "undefined function" (undefined_tramp) working properly.
;;; Try it with and without tail call elimination, since they can have
;;; different effects.  (Specifically, if undefined_tramp is incorrect
;;; a stunted stack can result from the tail call variant.)
(flet ((optimized ()
         (declare (optimize (speed 2) (debug 1))) ; tail call elimination
         (#:undefined-function 42))
       (not-optimized ()
         (declare (optimize (speed 1) (debug 2))) ; no tail call elimination
         (#:undefined-function 42))
       (test (fun)
         (declare (optimize (speed 1) (debug 2))) ; no tail call elimination
         (funcall fun)))

  (with-test (:name (:undefined-function :bug-346)
                    ;; Failures on ALPHA, SPARC, MIPS, and probably
                    ;; HPPA are due to not having a full and valid
                    ;; stack frame for the undefined function frame.
                    ;; See PPC undefined_tramp for details.
              :fails-on '(or :alpha :sparc :mips
                          (and :x86-64 :freebsd)))
    (assert (verify-backtrace
             (lambda () (test #'optimized))
             (list *undefined-function-frame*
                   (list `(flet test :in ,*p*) #'optimized)))))

  ;; bug 353: This test fails at least most of the time for x86/linux
  ;; ca. 0.8.20.16. -- WHN
  (with-test (:name (:undefined-function :bug-353))
    (assert (verify-backtrace
             (lambda () (test #'not-optimized))
             (list *undefined-function-frame*
                   (list `(flet not-optimized :in ,*p*))
                   (list `(flet test :in ,*p*) #'not-optimized))))))

(with-test (:name :backtrace-interrupted-condition-wait
            :skipped-on '(not :sb-thread)
                  ;; For some unfathomable reason the backtrace becomes
                  ;; stunted, ending at _sigtramp, when we add :TIMEOUT NIL to
                  ;; the frame we expect. If we leave it out, the backtrace is
                  ;; fine -- but the test fails. I can only boggle right now.
            :fails-on '(or (and :x86 :linux)
                           (and :win32 :sb-thread)))
  (let ((m (sb-thread:make-mutex))
        (q (sb-thread:make-waitqueue)))
    (assert (verify-backtrace
            (lambda ()
              (sb-thread:with-mutex (m)
                (handler-bind ((timeout (lambda (c)
                                          (error "foo"))))
                  (with-timeout 0.1
                    (sb-thread:condition-wait q m)))))
            `((sb-thread:condition-wait ,q ,m :timeout nil))))))

;;; Division by zero was a common error on PPC. It depended on the
;;; return function either being before INTEGER-/-INTEGER in memory,
;;; or more than MOST-POSITIVE-FIXNUM bytes ahead. It also depends on
;;; INTEGER-/-INTEGER calling SIGNED-TRUNCATE. I believe Raymond Toy
;;; says that the Sparc backend (at least for CMUCL) inlines this, so
;;; if SBCL does the same this test is probably not good for the
;;; Sparc.
;;;
;;; Disabling tail call elimination on this will probably ensure that
;;; the return value (to the flet or the enclosing top level form) is
;;; more than MOST-POSITIVE-FIXNUM with the current spaces on OS X.
;;; Enabling it might catch other problems, so do it anyway.
(flet ((optimized ()
         (declare (optimize (speed 2) (debug 1))) ; tail call elimination
         (/ 42 0))
       (not-optimized ()
         (declare (optimize (speed 1) (debug 2))) ; no tail call elimination
         (/ 42 0))
       (test (fun)
         (declare (optimize (speed 1) (debug 2))) ; no tail call elimination
         (funcall fun)))
  (with-test (:name (:divide-by-zero :bug-346)
              :fails-on :alpha)  ; bug 346
    (assert (verify-backtrace (lambda () (test #'optimized))
                              (list '(/ 42 &rest)
                                    (list `(flet test :in ,*p*) #'optimized)))))
  (with-test (:name (:divide-by-zero :bug-356)
              :fails-on :alpha)  ; bug 356
    (assert (verify-backtrace (lambda () (test #'not-optimized))
                              (list '(/ 42 &rest)
                                    `((flet not-optimized :in ,*p*))
                                    (list `(flet test :in ,*p*) #'not-optimized))))))

(with-test (:name (:throw :no-such-tag)
            :fails-on '(or
                        (and :sparc :linux)
                        :alpha
                        :mips))
  (progn
    (defun throw-test ()
      (throw 'no-such-tag t))
    (assert (verify-backtrace #'throw-test '((throw-test))))))

(defun bug-308926 (x)
  (let ((v "foo"))
    (flet ((bar (z)
             (oops v z)
             (oops z v)))
      (bar x)
      (bar v))))

(with-test (:name :bug-308926)
  (assert (verify-backtrace (lambda () (bug-308926 13))
                            '(((flet bar :in bug-308926) 13)
                              (bug-308926 &rest t)))))

;;; test entry point handling in backtraces

(defun oops ()
  (error "oops"))

(with-test (:name :xep-too-many-arguments)
  (assert (verify-backtrace (lambda () (oops 1 2 3 4 5 6))
                            '((oops ? ? ? ? ? ?)))))

(defmacro defbt (n ll &body body)
  ;; WTF is this? This is a way to make these tests not depend so much on the
  ;; details of LOAD/EVAL. Around 1.0.57 we changed %SIMPLE-EVAL to be
  ;; slightly smarter, which meant that things which used to have xeps
  ;; suddently had tl-xeps, etc. This takes care of that.
  `(funcall
    (compile nil
             '(lambda ()
               (progn
                 ;; normal debug info
                 (defun ,(intern (format nil "BT.~A.1" n)) ,ll
                   ,@body)
                 ;; no arguments saved
                 (defun ,(intern (format nil "BT.~A.2" n)) ,ll
                   (declare (optimize (debug 1) (speed 3)))
                   ,@body)
                 ;; no lambda-list saved
                 (defun ,(intern (format nil "BT.~A.3" n)) ,ll
                   (declare (optimize (debug 0)))
                   ,@body))))))

(defbt 1 (&key key)
  (list key))

(defbt 2 (x)
  (list x))

(defbt 3 (&key (key (oops)))
  (list key))

;;; ERROR instead of OOPS so that tail call elimination doesn't happen
(defbt 4 (&optional opt)
  (list (error "error")))

(defbt 5 (&optional (opt (oops)))
  (list opt))

(defmacro with-details (bool &body body)
  `(let ((sb-debug:*show-entry-point-details* ,bool))
     ,@body))

(defun bug-354 (x)
  (error "XEPs in backtraces: ~S" x))

(with-test (:name :bug-354)
  (with-details t
    (assert (not (verify-backtrace (lambda () (bug-354 354))
                                   '((bug-354 &rest)
                                     ((sb-c::tl-xep bug-354) &rest))))))
  (assert (verify-backtrace (lambda () (bug-354 354)) '((bug-354 354)))))

;;; FIXME: This test really should be broken into smaller pieces
(with-test (:name (:backtrace :tl-xep))
  (with-details t
    (assert (verify-backtrace #'namestring
                              '(((sb-c::tl-xep namestring) 0 ?)))))
  (with-details nil
    (assert (verify-backtrace #'namestring
                              '((namestring))))))

(with-test (:name (:backtrace :more-processor))
  (with-details t
    (assert (verify-backtrace (lambda () (bt.1.1 :key))
                              '(((sb-c::&more-processor bt.1.1) &rest))))
    (assert (verify-backtrace (lambda () (bt.1.2 :key))
                              '(((sb-c::&more-processor bt.1.2) &rest))))
    (assert (verify-backtrace (lambda () (bt.1.3 :key))
                              '(((sb-c::&more-processor bt.1.3) &rest)))))
  (with-details nil
    (assert (verify-backtrace (lambda () (bt.1.1 :key))
                              '((bt.1.1 :key))))
    (assert (verify-backtrace (lambda () (bt.1.2 :key))
                              '((bt.1.2 &rest))))
    (assert (verify-backtrace (lambda () (bt.1.3 :key))
                              '((bt.1.3 &rest))))))

(with-test (:name (:backtrace :xep))
  (with-details t
    (assert (verify-backtrace #'bt.2.1
                              '(((sb-c::xep bt.2.1) 0 ?))))
    (assert (verify-backtrace #'bt.2.2
                              '(((sb-c::xep bt.2.2) &rest))))
    (assert (verify-backtrace #'bt.2.3
                              '(((sb-c::xep bt.2.3) &rest)))))
  (with-details nil
    (assert (verify-backtrace #'bt.2.1
                              '((bt.2.1))))
    (assert (verify-backtrace #'bt.2.2
                              '((bt.2.2 &rest))))
    (assert (verify-backtrace #'bt.2.3
                              '((bt.2.3 &rest))))))

;;; This test is somewhat deceptively named. Due to confusion in debug naming
;;; these functions used to have sb-c::varargs-entry debug names for their
;;; main lambda.
(with-test (:name (:backtrace :varargs-entry))
  (with-details t
    (assert (verify-backtrace #'bt.3.1
                              '((bt.3.1 :key nil))))
    (assert (verify-backtrace #'bt.3.2
                              '((bt.3.2 :key ?))))
    (assert (verify-backtrace #'bt.3.3
                              '((bt.3.3 &rest)))))
  (with-details nil
    (assert (verify-backtrace #'bt.3.1
                              '((bt.3.1 :key nil))))
    (assert (verify-backtrace #'bt.3.2
                              '((bt.3.2 :key ?))))
    (assert (verify-backtrace #'bt.3.3
                              '((bt.3.3 &rest))))))

;;; This test is somewhat deceptively named. Due to confusion in debug naming
;;; these functions used to have sb-c::hairy-args-processor debug names for
;;; their main lambda.
(with-test (:name (:backtrace :hairy-args-processor))
  (with-details t
    (assert (verify-backtrace #'bt.4.1
                              '((bt.4.1 ?))))
    (assert (verify-backtrace #'bt.4.2
                              '((bt.4.2 ?))))
    (assert (verify-backtrace #'bt.4.3
                              '((bt.4.3 &rest)))))
  (with-details nil
    (assert (verify-backtrace #'bt.4.1
                              '((bt.4.1 ?))))
    (assert (verify-backtrace #'bt.4.2
                              '((bt.4.2 ?))))
    (assert (verify-backtrace #'bt.4.3
                              '((bt.4.3 &rest))))))


(with-test (:name (:backtrace :optional-processor))
  (with-details t
    (assert (verify-backtrace #'bt.5.1
                              '(((sb-c::&optional-processor bt.5.1)))))
    (assert (verify-backtrace #'bt.5.2
                              '(((sb-c::&optional-processor bt.5.2) &rest))))
    (assert (verify-backtrace #'bt.5.3
                              '(((sb-c::&optional-processor bt.5.3) &rest)))))
  (with-details nil
    (assert (verify-backtrace #'bt.5.1
                              '((bt.5.1))))
    (assert (verify-backtrace #'bt.5.2
                              '((bt.5.2 &rest))))
    (assert (verify-backtrace #'bt.5.3
                              '((bt.5.3 &rest))))))

(write-line "//compile nil")
(defvar *compile-nil-error* (compile nil '(lambda (x) (cons (when x (error "oops")) nil))))
(defvar *compile-nil-non-tc* (compile nil '(lambda (y) (cons (funcall *compile-nil-error* y) nil))))
(with-test (:name (:compile nil))
  (assert (verify-backtrace (lambda () (funcall *compile-nil-non-tc* 13))
                            `(((lambda (x) :in ,*p*) 13)
                              ((lambda (y) :in ,*p*) 13)))))

(with-test (:name :clos-slot-typecheckfun-named)
  (assert
   (verify-backtrace
    (lambda ()
      (eval `(locally (declare (optimize safety))
               (defclass clos-typecheck-test ()
                 ((slot :type fixnum)))
               (setf (slot-value (make-instance 'clos-typecheck-test) 'slot) t))))
    '(((sb-pcl::slot-typecheck fixnum) t)))))

(with-test (:name :clos-emf-named)
  (assert
   (verify-backtrace
    (lambda ()
      (eval `(progn
               (defmethod clos-emf-named-test ((x symbol)) x)
               (defmethod clos-emf-named-test :before (x) (assert x))
               (clos-emf-named-test nil))))
    '(((sb-pcl::emf clos-emf-named-test) ? ? nil)))))

(with-test (:name :bug-310173)
  (flet ((make-fun (n)
           (let* ((names '(a b))
                  (req (loop repeat n collect (pop names))))
             (compile nil
                      `(lambda (,@req &rest rest)
                         (let ((* *)) ; no tail-call
                           (apply '/ ,@req rest)))))))
    (assert
     (verify-backtrace (lambda ()
                         (funcall (make-fun 0) 10 11 0))
                       `((sb-kernel:two-arg-/ 10/11 0)
                         (/ 10 11 0)
                         ((lambda (&rest rest) :in ,*p*) 10 11 0))))
    (assert
     (verify-backtrace (lambda ()
                         (funcall (make-fun 1) 10 11 0))
                       `((sb-kernel:two-arg-/ 10/11 0)
                         (/ 10 11 0)
                         ((lambda (a &rest rest) :in ,*p*) 10 11 0))))
    (assert
     (verify-backtrace (lambda ()
                         (funcall (make-fun 2) 10 11 0))
                       `((sb-kernel:two-arg-/ 10/11 0)
                         (/ 10 11 0)
                         ((lambda (a b &rest rest) :in ,*p*) 10 11 0))))))

;;;; test TRACE

(defun trace-this ()
  'ok)

(defun trace-fact (n)
  (if (zerop n)
      1
      (* n (trace-fact (1- n)))))

(with-test (:name (trace :simple))
  (let ((out (with-output-to-string (*trace-output*)
               (trace trace-this)
               (assert (eq 'ok (trace-this)))
               (untrace))))
    (assert (search "TRACE-THIS" out))
    (assert (search "returned OK" out))))

;;; bug 379
;;; This is not a WITH-TEST :FAILS-ON PPC DARWIN since there are
;;; suspicions that the breakpoint trace might corrupt the whole image
;;; on that platform.
(with-test (:name (trace :encapsulate nil)
            :fails-on '(or (and :ppc (not :linux)) :sparc :mips)
            :broken-on '(or :darwin :sunos))
  (let ((out (with-output-to-string (*trace-output*)
               (trace trace-this :encapsulate nil)
               (assert (eq 'ok (trace-this)))
               (untrace))))
    (assert (search "TRACE-THIS" out))
    (assert (search "returned OK" out))))

(with-test (:name (trace-recursive :encapsulate nil)
            :fails-on '(or (and :ppc (not :linux)) :sparc :mips :sunos)
            :broken-on '(or :darwin (and :x86 :sunos)))
  (let ((out (with-output-to-string (*trace-output*)
               (trace trace-fact :encapsulate nil)
               (assert (= 120 (trace-fact 5)))
               (untrace))))
    (assert (search "TRACE-FACT" out))
    (assert (search "returned 1" out))
    (assert (search "returned 120" out))))

(defun trace-and-fmakunbound-this (x)
  x)

(with-test (:name :bug-667657)
  (trace trace-and-fmakunbound-this)
  (fmakunbound 'trace-and-fmakunbound-this)
  (untrace)
  (assert (not (trace))))

(with-test (:name :bug-414)
  (handler-bind ((warning #'error))
    (load (compile-file "bug-414.lisp"))
    (disassemble 'bug-414)))

(with-test (:name :bug-310175 :fails-on '(not :stack-allocatable-lists))
  ;; KLUDGE: Not all DX-enabled platforms DX CONS, and the compiler
  ;; transforms two-arg-LIST* (and one-arg-LIST) to CONS.  Therefore,
  ;; use two-arg-LIST, which should get through to VOP LIST, and thus
  ;; stack-allocate on a predictable set of machines.
  (let ((dx-arg (list t t)))
    (declare (dynamic-extent dx-arg))
    (flet ((dx-arg-backtrace (x)
             (declare (optimize (debug 2)))
             (prog1 (sb-debug:backtrace-as-list 10)
               (assert (sb-debug::stack-allocated-p x)))))
      (declare (notinline dx-arg-backtrace))
      (assert (member-if (lambda (frame)
                           (and (consp frame)
                                (consp (car frame))
                                (equal '(flet dx-arg-backtrace :in) (butlast (car frame)))
                                (notany #'sb-debug::stack-allocated-p (cdr frame))))
                         (dx-arg-backtrace dx-arg))))))

(with-test (:name :bug-795245)
  (assert
   (eq :ok
       (catch 'done
         (handler-bind
             ((error (lambda (e)
                       (declare (ignore e))
                       (handler-case
                           (sb-debug:backtrace 100 (make-broadcast-stream))
                         (error ()
                           (throw 'done :error))
                         (:no-error ()
                           (throw 'done :ok))))))
           (apply '/= nil 1 2 nil))))))

;;;; test infinite error protection

(defmacro nest-errors (n-levels error-form)
  (if (< 0 n-levels)
      `(handler-bind ((error (lambda (condition)
                               (declare (ignore condition))
                               ,error-form)))
        (nest-errors ,(1- n-levels) ,error-form))
      error-form))

(defun erroring-debugger-hook (condition old-debugger-hook)
  (let ((*debugger-hook* old-debugger-hook))
    (format t "recursive condition: ~A~%" condition) (force-output)
    (error "recursive condition: ~A" condition)))

(defun test-inifinite-error-protection ()
  ;; after 50 successful throws to SB-IMPL::TOPLEVEL-CATCHER sbcl used
  ;; to halt, it produces so much garbage that's hard to suppress that
  ;; it is tested only once
  (write-line "--HARMLESS BUT ALARMING BACKTRACE COMING UP--")
  (let ((*debugger-hook* #'erroring-debugger-hook))
    (loop repeat 1 do
          (let ((error-counter 0)
                (*terminal-io* (make-broadcast-stream)))
            (assert
             (not (eq
                   :normal-exit
                   (catch 'sb-impl::toplevel-catcher
                     (nest-errors 20 (error "infinite error ~s"
                                            (incf error-counter)))
                     :normal-exit)))))))
  (write-line "--END OF H-B-A-B--"))

(with-test (:name infinite-error-protection)
  (enable-debugger)
  (test-inifinite-error-protection))

(with-test (:name (infinite-error-protection :thread)
                  :skipped-on '(not :sb-thread))
  (enable-debugger)
  (let ((thread (sb-thread:make-thread #'test-inifinite-error-protection)))
    (loop while (sb-thread:thread-alive-p thread))))

;; unconditional, in case either previous left it enabled
(disable-debugger)

;;;; test some limitations of MAKE-LISP-OBJ

;;; Older GENCGC systems had a bug in the pointer validation used by
;;; MAKE-LISP-OBJ that made SIMPLE-FUN objects always fail to
;;; validate.
(with-test (:name (make-lisp-obj :simple-funs))
  (sb-sys:without-gcing
    (assert (eq #'identity
                (sb-kernel:make-lisp-obj
                 (sb-kernel:get-lisp-obj-address
                  #'identity))))))

;;; Older CHENEYGC systems didn't perform any real pointer validity
;;; checks beyond "is this pointer to somewhere in heap space".
(with-test (:name (make-lisp-obj :pointer-validation))
  ;; Fun and games: We need to test MAKE-LISP-OBJ with a known-bogus
  ;; address, but we also need the GC to not pitch a fit if it sees an
  ;; object with said bogus address.  Thus, construct our known-bogus
  ;; object within an area of unboxed storage (a vector) in static
  ;; space.  We'll make it a simple object, (CONS 0 0), which has an
  ;; in-memory representation of two consecutive zero words.  We
  ;; allocate a three-word vector so that we can guarantee a
  ;; double-word aligned double-word of zeros no matter what happens
  ;; with the vector-data-offset (currently double-word aligned).
  (let* ((memory (sb-int:make-static-vector 3 :element-type `(unsigned-byte ,sb-vm:n-word-bits)
                                            :initial-element 0))
         (vector-data-address (sb-sys:sap-int (sb-kernel::vector-sap memory)))
         (object-base-address (logandc2 (+ vector-data-address sb-vm:lowtag-mask) sb-vm:lowtag-mask))
         (object-tagged-address (+ object-base-address sb-vm:list-pointer-lowtag)))
    (multiple-value-bind (object valid-p)
        (sb-kernel:make-lisp-obj object-tagged-address nil)
      (declare (ignore object))
      (assert (not valid-p)))))

(defun test-debugger (control form &rest targets)
  (let ((out (make-string-output-stream))
        (oops t))
    (unwind-protect
         (progn
           (with-simple-restart (debugger-test-done! "Debugger Test Done!")
             (let* ((*debug-io* (make-two-way-stream
                                 (make-string-input-stream control)
                                 (make-broadcast-stream out #+nil *standard-output*)))
                    ;; Initial announcement goes to *ERROR-OUTPUT*
                    (*error-output* *debug-io*)
                    (*invoke-debugger-hook* nil))
               (handler-bind ((error #'invoke-debugger))
                 (eval form))))
           (setf oops nil))
      (when oops
        (error "Uncontrolled unwind from debugger test.")))
    ;; For sanity's sake this is outside the *debug-io* rebinding -- otherwise
    ;; it could swallow our asserts!
    (with-input-from-string (s (get-output-stream-string out))
      (loop for line = (read-line s nil)
            while line
            do (assert targets)
               #+nil
               (format *error-output* "Got: ~A~%" line)
               (let ((match (pop targets)))
                 (if (eq '* match)
                     ;; Whatever, till the next line matches.
                     (let ((text (pop targets)))
                       #+nil
                       (format *error-output* "Looking for: ~A~%" text)
                       (unless (search text line)
                         (push text targets)
                         (push match targets)))
                     (unless (search match line)
                       (format *error-output* "~&Wanted: ~S~%   Got: ~S~%" match line)
                       (setf oops t))))))
    ;; Check that we saw everything we wanted
    (when targets
      (error "Missed: ~S" targets))
    (assert (not oops))))

(with-test (:name (:debugger :source 1))
  (test-debugger
   "d
    source 0
    debugger-test-done!"
   `(progn
      (defun this-will-break (x)
               (declare (optimize debug))
               (let* ((y (- x x))
                      (z (/ x y)))
                 (+ x z)))
      (this-will-break 1))
   '*
   "debugger invoked"
   '*
   "DIVISION-BY-ZERO"
   "operands (1 0)"
   '*
   "INTEGER-/-INTEGER"
   "(THIS-WILL-BREAK 1)"
   "1]"
   "(/ X Y)"
   "1]"))

(with-test (:name (:debugger :source 2))
  (test-debugger
   "d
    source 0
    debugger-test-done!"
   `(locally (declare (optimize (speed 0) (safety 3) (debug 3)))
      (let ((f #'(lambda (x cont)
                   (print x (make-broadcast-stream))
                   (if (zerop x)
                       (error "~%foo")
                       (funcall cont (1- x) cont)))))
        (funcall f 10 f)))
   '*
   "debugger"
   '*
   "foo"
   '*
   "source: (ERROR \"~%foo\")"
   '*
   "(LAMBDA (X CONT)"
   '*
   "(FUNCALL CONT (1- X) CONT)"
   "1]"))

(with-test (:name (disassemble :high-debug-eval))
  (eval `(defun this-will-be-disassembled (x)
           (declare (optimize debug))
           (+ x x)))
  (let* ((oopses (make-string-output-stream))
         (disassembly
           (let ((*error-output* oopses))
             (with-output-to-string (*standard-output*)
               (disassemble 'this-will-be-disassembled)))))
    (with-input-from-string (s disassembly)
      (assert (search "; disassembly for THIS-WILL-BE-DISASSEMBLED"
                      (read-line s))))
    (let ((problems (get-output-stream-string oopses)))
      (unless (zerop (length problems))
        (error problems)))))

(defun this-too-will-be-disasssembled (x)
  (declare (optimize debug))
  (+ x x))

(with-test (:name (disassemble :high-debug-load))
  (let* ((oopses (make-string-output-stream))
         (disassembly
           (let ((*error-output* oopses))
             (with-output-to-string (*standard-output*)
               (disassemble 'this-too-will-be-disasssembled)))))
    (with-input-from-string (s disassembly)
      (assert (equal "; disassembly for THIS-TOO-WILL-BE-DISASSSEMBLED"
                     (read-line s))))
    (let ((problems (get-output-stream-string oopses)))
      (unless (zerop (length problems))
        (error problems)))))

(write-line "/debug.impure.lisp done")

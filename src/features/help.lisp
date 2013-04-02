;;; Copyright 2012-2013 CommonGoods Network, Inc.
;;;
;;; This file is part of Kindista.
;;;
;;; Kindista is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU Affero General Public License as published
;;; by the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; Kindista is distributed in the hope that it will be useful, but WITHOUT
;;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;;; License for more details.
;;;
;;; You should have received a copy of the GNU Affero General Public License
;;; along with Kindista.  If not, see <http://www.gnu.org/licenses/>.

(in-package :kindista)

(defun help-tabs-html (&key tab)
  (html
    (:menu :class "bar"
      (:h3 :class "label" "Profile Menu")
      (if (eql tab :faqs)
        (htm (:li :class "selected" "Frequent Questions"))
        (htm (:li (:a :href "/help/faq-page" "Frequent Questions"))))
      (if (eql tab :feedback)
        (htm (:li :class "selected" "Feedback"))
        (htm (:li (:a :href "/help/feedback" "Feedback"))))
      )))

(defun faqs-html ()
  (html
    (str (help-tabs-html :tab :faqs))
    (:div :class "legal faqs"
      (str (markdown-file (s+ +markdown-path+ "faq.md"))))))

(defun get-help () 
  (standard-page
    "Help and Feedback"
    (html
      (:h1 "Help and Feedback")
      (str (faqs-html)))
    :selected "help"
    :right (html
             (str (donate-sidebar))
             (str (invite-sidebar)))))
             
(defun get-faqs ()
  (standard-page 
    "Frequently Asked Questions" 
    (html
      (:h1 "Help and Feedback")
      (str (faqs-html)))
    :selected "help"
    :right (html
             (str (donate-sidebar))
             (str (invite-sidebar)))))



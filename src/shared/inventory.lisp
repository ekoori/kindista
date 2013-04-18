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


(defun create-inventory-item (&key type (by *userid*) text tags)
  (insert-db (list :type type
                   :by by
                   :text text
                   :tags tags
                   :created (get-universal-time))))

(defun index-inventory-item (id data)
  (let* ((by (getf data :by))
         (type (getf data :type))
         (result (make-result :latitude (or (getf data :lat) (getf (db (getf data :by)) :lat))
                              :longitude (or (getf data :long) (getf (db (getf data :by)) :long))
                              :id id
                              :type type
                              :people (list by)
                              :time (or (getf data :edited) (getf data :created))
                              :tags (getf data :tags))))

    (with-locked-hash-table (*db-results*)
      (setf (gethash id *db-results*) result))

    (if (eq type :offer)
      (with-locked-hash-table (*offer-index*)
        (push id (gethash by *offer-index*)))
      (with-locked-hash-table (*request-index*)
        (push id (gethash by *request-index*))))

    (let ((stems (stem-text (getf data :text))))
      (if (eq type :offer)
        (with-locked-hash-table (*offer-stem-index*)
          (dolist (stem stems)
            (push result (gethash stem *offer-stem-index*)))) 
        (with-locked-hash-table (*request-stem-index*)
          (dolist (stem stems)
            (push result (gethash stem *request-stem-index*))))))

    (with-locked-hash-table (*activity-person-index*)
      (asetf (gethash by *activity-person-index*)
             (sort (push result it) #'> :key #'result-time)))

    (if (eq type :offer)
      (geo-index-insert *offer-geo-index* result)
      (geo-index-insert *request-geo-index* result))
    (geo-index-insert *activity-geo-index* result)))

(defun modify-inventory-item (id &key text tags latitude longitude)
  (let* ((result (gethash id *db-results*))
         (type (result-type result))
         (data (db id))
         (now (get-universal-time)))

    (when text
      (let* ((oldstems (stem-text (getf data :text)))
             (newstems (stem-text text))
             (common (intersection oldstems newstems :test #'string=)))

        (flet ((commonp (stem)
                 (member stem common :test #'string=)))

          (setf oldstems (delete-if #'commonp oldstems))
          (setf newstems (delete-if #'commonp newstems))
          
          (when (eq type :offer)          
            (with-locked-hash-table (*offer-stem-index*)
              (dolist (stem oldstems)
                (asetf (gethash stem *offer-stem-index*)
                       (remove result it))))
              (dolist (stem newstems)
                (push result (gethash stem *offer-stem-index*))))

          (when (eq type :request)          
            (with-locked-hash-table (*request-stem-index*)
              (dolist (stem oldstems)
                (asetf (gethash stem *request-stem-index*)
                       (remove result it))))
              (dolist (stem newstems)
                (push result (gethash stem *request-stem-index*)))))))

    (unless (equal tags (getf data :tags))
      (setf (result-tags result) tags))

    (when (and latitude
               longitude
               (or (not (eql latitude (getf data :lat)))
                   (not (eql longitude (getf data :long)))))

      (if (eq type :offer)          
        (geo-index-remove *offer-geo-index* result)  
        (geo-index-remove *request-geo-index* result))
      (geo-index-remove *activity-geo-index* result)
      (setf (result-latitude result) latitude)
      (setf (result-longitude result) longitude)
      (if (eq type :offer)          
        (geo-index-insert *offer-geo-index* result)  
        (geo-index-insert *request-geo-index* result))
      (geo-index-insert *activity-geo-index* result))

    (setf (result-time result) now)
    
    (with-locked-hash-table (*activity-person-index*)
      (asetf (gethash id *activity-person-index*)
             (sort it #'> :key #'result-time)))
    
    (modify-db id :text text :tags tags :lat latitude :long longitude :edited now)))

(defun delete-inventory-item (id)
  (let* ((result (gethash id *db-results*))
         (type (result-type result))
         (data (db id)))

    (when (eq type :offer)
      (with-locked-hash-table (*offer-index*)
        (asetf (gethash (getf data :by) *offer-index*)
               (remove id it)))
      (let ((stems (stem-text (getf data :text))))
        (with-locked-hash-table (*offer-stem-index*)
          (dolist (stem stems)
            (asetf (gethash stem *offer-stem-index*)
                   (remove result it)))))
      (geo-index-remove *offer-geo-index* result))

    (when (eq type :request)
      (with-locked-hash-table (*request-index*)
        (asetf (gethash (getf data :by) *request-index*)
               (remove id it)))
      (let ((stems (stem-text (getf data :text))))
        (with-locked-hash-table (*request-stem-index*)
          (dolist (stem stems)
            (asetf (gethash stem *request-stem-index*)
                   (remove result it)))))
      (geo-index-remove *request-geo-index* result))

    (with-locked-hash-table (*love-index*)
      (dolist (person-id (gethash id *love-index*))
        (amodify-db person-id :loves (remove id it))))

    (with-locked-hash-table (*activity-person-index*)
      (asetf (gethash (getf data :by) *activity-person-index*)
             (remove result it)))

    (geo-index-remove *activity-geo-index* result)

    (with-locked-hash-table (*db-results*)
      (remhash id *db-results*))
    
    (remove-from-db id)))

(defun post-new-inventory-item (type &key url)
  (require-active-user
    (cond
      ((post-parameter "cancel")
       (see-other (or (post-parameter "next") "/home")))

      ((post-parameter "back")
       (enter-inventory-text :type type
                             :text (post-parameter "text")
                             :action url
                             :selected (s+ type "s")))

      ((and (post-parameter "next")
            (post-parameter "text"))
        (enter-inventory-tags :title (s+ "Preview your " type)
                              :text (post-parameter "text")
                              :action url
                              :button-text (s+ "Post " type)
                              :selected (s+ type "s")))

      ((and (post-parameter "create")
            (post-parameter "text")) 

       (let ((tags (iter (for pair in (post-parameters*))
                         (when (and (string= (car pair) "tag")
                                    (scan *tag-scanner* (cdr pair)))
                           (collect (cdr pair))))))
         (iter (for tag in (tags-from-string (post-parameter "tags")))
               (setf tags (cons tag tags)))
         
         (if (intersection tags *top-tags* :test #'string=)
           (see-other 
             (format nil (s+ "/" type "s/~A")
               (create-inventory-item :type (if (string= type "request") :request
                                                                         :offer)
                                      :text (post-parameter "text") 
                                      :tags tags)))

           (enter-inventory-tags :title (s+ "Preview your " type)
                                 :text (post-parameter "text")
                                 :action url
                                 :button-text (s+ "Post " type)
                                 :tags tags
                                 :error "You must select at least one keyword"
                                 :selected (s+ type "s")))))
      (t
       (enter-inventory-text :type type
                             :text (post-parameter "text")
                             :action url
                             :selected (s+ type "s"))))))

(defun post-existing-inventory-item (type &key id url)
  (require-user
    (let ((item (db (parse-integer id))))
      (require-test ((eql *userid* (getf item :by))
                    (s+ "You can only edit your own " type "s."))
        (cond
          ((post-parameter "delete")
           (confirm-delete :url url
                           :type type
                           :text (getf item :text)
                           :next-url (referer)))

          ((post-parameter "really-delete")
           (delete-inventory-item (parse-integer id))
           (flash (s+ "Your " type " has been deleted!"))
           (see-other (or (post-parameter "next") "/home")))

          ((post-parameter "back")
           (enter-inventory-text :type type
                                 :text (post-parameter "text")
                                 :action url
                                 :selected (s+ type "s")))

          ((and (post-parameter "next")
                (post-parameter "text"))

           (enter-inventory-tags :title (s+ "Edit your " type)
                                 :action url
                                 :text (post-parameter "text")
                                 :tags (getf item :tags)
                                 :button-text (s+ "Save " type)
                                 :selected (s+ type "s")))

          ((and (post-parameter "create")
                (post-parameter "text")) 

           (let ((tags (iter (for pair in (post-parameters*))
                             (when (and (string= (car pair) "tag")
                                        (scan *tag-scanner* (cdr pair)))
                               (collect (cdr pair))))))
             (iter (for tag in (tags-from-string (post-parameter "tags")))
                   (setf tags (cons tag tags)))
             
             (if (intersection tags *top-tags* :test #'string=)
               (progn
                 (modify-inventory-item (parse-integer id) :text (post-parameter "text")
                                                     :tags tags)
                                                                     
                 (see-other (s+ "/" type "s/" id)))

               (enter-inventory-tags :title (s+ "Edit your " type)
                                     :action url
                                     :text (post-parameter "text")
                                     :tags tags
                                     :button-text (s+ "Save " type)
                                     :error "You must select at least one keyword"
                                     :selected (s+ type "s")))))

          (t
            (enter-inventory-tags :title (s+ "Edit your " type)
                                  :action url
                                  :text (getf item :text)
                                  :tags (getf item :tags)
                                  :button-text (s+ "Save " type)
                                  :selected (s+ type "s"))))))))

(defun simple-inventory-entry-html (preposition type)
  (html 
    (:div :class "item"
      (:h4 (str (s+ "post " preposition " " type))) 
      (:form :method "post" :action (s+ "/" type "s/new") 
        (:table :class "post"
          (:tr
            (:td (:textarea :cols "150" :rows "4" :name "text"))
            (:td
              (:button :class "yes" :type "submit" :class "submit" :name "next" "Post"))))))))

(defun enter-inventory-text (&key type title text action selected)
  (standard-page 
    (or title (if (string= type "offer")
                  "Post an offer"
                  "Post a request"))
    (html
      (:div :class "item"
         (:h2 (if (string= selected "offers")
                (str "Please describe your offer")
                (str "Please describe your request")))
         (:form :method "post" :action action
           (:textarea :cols "40" :rows "8" :name "text" (str text))
           (:p  (:button :class "no" :type "submit" :class "cancel" :name "cancel" "Cancel")
           (:button :class "yes" :type "submit" :class "submit" :name "next" "Next")))))
   :selected selected))

(defun enter-inventory-tags (&key title action text error tags button-text selected)
  ; show the list of top-level tags
  ; show recommended tags
  ; show preview
  ; cancel button
  ; edit (back) button
  ; create button
  (let ((suggested (or tags (get-tag-suggestions text))))
    (standard-page title
     (html
       (:div :class "item"
        (:h2 title )
        (when error
          (htm
            (:p :class "error" (str error))))
        (:form :class "post-next"
               :method "post" 
               :action action
          (:input :type "hidden" :name "text" :value (escape-for-html text))
          (:p (cl-who:esc text)
              " "
              (:button :class "red" :type "submit" :class "cancel" :name "back" "edit")) 
          (:h2 "select at least one keyword")
          (dolist (tag *top-tags*)
            (htm 
              (:div :class "tag"
                (:input :type "checkbox"
                        :name "tag"
                        :value tag
                        :checked (when (member tag suggested :test #'string=)
                                   (setf suggested (remove tag suggested :test #'string=))
                                   ""))
                   (:span (str tag)))))
          (:h2 "additional keywords (optional)")
          (:input :type "text" :name "tags" :size 40
                  :placeholder "e.g. produce, bicycle, tai-chi"
                  :value (format nil "~{~a~^,~^ ~}" suggested))

          (:p (:button :class "yes" 
                       :type "submit" 
                       :class "submit" 
                       :name "create" 
                       (str button-text)
                       )))))
     :selected selected)))

; author
; creation date
; edited date
; text
; tags (at least 1)
; privacy ('all 'contacts or listname)

(defun nearby-inventory-items (type &key base (subtag-count 4) (distance 50) q)
  (with-location
    (let ((nearby (sort
                    (if q
                      (result-id-intersection
                        (geo-index-query (case type
                                           (:offer *offer-geo-index*)
                                           (t *request-geo-index*))
                                         *latitude*
                                         *longitude*
                                         distance)
                        (stem-index-query (case type
                                           (:offer *offer-stem-index*)
                                           (t *request-stem-index*))
                                          q))
                      (geo-index-query (case type
                                         (:offer *offer-geo-index*)
                                         (t *request-geo-index*))
                                         *latitude*
                                         *longitude*
                                       distance)) 
                    #'> :key #'inventory-rank))
          (items nil))
      (let ((tags (make-hash-table :test 'equalp)))
        (dolist (item nearby)
          (dolist (tag (result-tags item))
            (push item (gethash tag tags))))

        (if base
          ; get each base tag's list of items
          ; get intersection of those lists
          ; remove base tags from hashtable
          ; set all remaining tags lists to be intersection of tag list and previous intersection
          (progn
            (setf items (iter (for tag in base)
                              (reducing (gethash tag tags) by #'result-id-intersection)
                              (remhash tag tags))) 
            (iter (for (tag tag-items) in-hashtable tags)
                  (let ((new-items (intersection tag-items items :key #'result-id)))
                    (if new-items
                      (setf (gethash tag tags) new-items)
                      (remhash tag tags)))))
          
          (setf items nearby))
                

        ; for each tag, number of contents + ordered list of subtags (up to 4)
        
        (values (iter (for (tag tag-items) in-hashtable tags)
                      (collect (list tag
                                     (length tag-items)
                                     (when (cdr tag-items)
                                       (let* ((subtags (sort
                                                         (iter (for (subtag subtag-items) in-hashtable tags)
                                                               (unless (string= tag subtag)
                                                                 (awhen (intersection tag-items subtag-items :key #'result-id)
                                                                   (collect (cons subtag (length it))))))
                                                         #'> :key #'cdr))
                                              (top-subtags (subseq subtags 0
                                                                   (min (length subtags) subtag-count))))
                                         (if (< subtag-count (length subtags))
                                           (append (sort (subseq top-subtags 0 (- subtag-count 1))
                                                         #'string< :key #'car)
                                                   (list
                                                     (cons
                                                       "more"
                                                       (reduce #'+ (subseq subtags (- subtag-count 1)) :key #'cdr))))
                                           (sort top-subtags #'string< :key #'car)))))))
                                                       
                items)))))

(defun nearby-inventory-top-tags (type &key (count 9) (more t) base (subtag-count 4) q)
  (multiple-value-bind (nearby items)
      (nearby-inventory-items type :base base :subtag-count subtag-count :q q)
    (let* ((tags (sort (if base
                         nearby
                         (remove-if-not #'top-tag-p nearby :key #'first))
                       #'> :key #'second))
           (top-tags (subseq tags 0 (min count (length tags))))) 
      (cond
        ((and more (> (length tags) (+ count 1)))
         (values
           (append (sort top-tags #'string< :key #'first)
                   (list
                     (let* ((more-tags (subseq tags count))
                            (subtags (iter (for tag in (subseq more-tags 0
                                                               (min 6 (length more-tags))))
                                           (collect
                                             (cons (first tag) (second tag))))))
                       (list "etc"
                         (reduce #'+ more-tags :key #'second)
                         (if (< 6 (length more-tags))
                           (append (sort (subseq subtags 0 5) #'string< :key #'car)
                                   (list
                                     (cons "more" (reduce #'+ (subseq more-tags 5) :key #'second))))
                           (sort subtags #'string< :key #'car))))))
                 items))
        ((and more (= (length tags) (+ count 1)))
         (values (sort tags #'string< :key #'first) items))
        (t
         (values (sort top-tags #'string< :key #'first) items))))))

(defun inventory-body-html (type &key base q items start page preposition)
  (html
    (let ((base-url (s+ "/" type "s")))
      (htm
        (:div :class "activity"
          (:div :class "item"
            (unless (or (not *user*) 
                        (eq (getf *user* :active) nil)
                        base
                        q)
              (str (simple-inventory-entry-html preposition type)))
            
            (when q
              (htm
                (:span (:strong :class "small" (str (s+ "showing " type "s matching \"")) (str q) (:strong "\"")))))
            (str (rdist-selection-html (url-compose base-url "q" q "kw" base)
                                       :style "display:inline;"
                                       :text (if q " within "
                                                   "showing results within "))))
          (:span
            (when (or base q)
              (htm
                (:span :style "float: right;" (:a :href (str base-url) 
                                                        (str (s+"show all " type "s")))))))
          (iter (for i from 0 to (+ start 20))
                (cond
                  ((< i start)
                   (pop items))

                  ((and (>= i start) items)
                   (str (inventory-activity-item type
                                                 (pop items) 
                                                 :show-distance t)))
                  (t
                   (when (< (user-rdist) 100)
                     (htm
                       (:div :class "item small"
                        (:em "Increasing the ")(:strong "show results within")(:em " distance may yield more results."))))
                   (finish)))

                (finally
                  (when (or (> page 0) (cdr items))
                    (htm
                      (:div :class "item"
                       (when (> page 0)
                         (htm
                           (:a :href (url-compose base-url "p" (- page 1) "kw" base) "< previous page")))
                       "&nbsp;"
                       (when (cdr items)
                         (htm
                           (:a :style "float: right;" 
                               :href (url-compose base-url "p" (+ page 1) "kw" base) 
                               "next page >")))))))))))))

(defun browse-inventory-tags (type &key q base tags)
  (let ((base-url (s+ "/" type "s")))
    (html
      (when base
        (htm
          (:p (:strong "categories selected: ")) 
          (:ul :class "keywords"
            (dolist (tag base)
              (htm
                (:li
                  (:a :href (url-compose base-url "kw" tag "q" q) (str tag)) 
                  " "
                  (:a :href (url-compose base-url "kw" (remove tag base :test #'string=) "q" q)
                      "[x]")      
                  ))))))
      (:h3 "filter by category")
      (dolist (tag tags)
        (if (string= (first tag) "etc")
          (htm
            (:div :class "category"
             (:h3 (:a :href (str (s+ base-url "/all"))
                      (str (s+ "etc (" (write-to-string (second tag)) ")"))))
             (iter (for subtag in (third tag))
                   (for i downfrom (length (third tag)))
                   (htm
                     (:a :href (if (string= (first subtag) "more")
                                 (str (s+ base-url "/all"))
                                 (url-compose "" "kw" (format nil "~{~a+~}~a" base (first subtag)) "q" q) )
                         (str (s+ (car subtag) " (" (write-to-string (cdr subtag)) ")")))
                     (unless (= i 1)
                       (str ", "))))))
          (htm
            (:div :class "category"
             (:h3 (:a :href (url-compose "" "kw" (format nil "~{~a+~}~a" base (first tag)) "q" q)
                      (str (s+ (first tag) " (" (write-to-string (second tag)) ")"))))
             (iter (for subtag in (third tag))
                   (for i downfrom (length (third tag)))
                   (htm
                     (:a :href (url-compose "" "kw"
                                            (if (string= (first subtag) "more")
                                              (format nil "~{~a+~}~a" base (first tag))
                                              (format nil "~{~a+~}~a+~a" base (first tag) (first subtag)))
                                            "q" q)
                         (str (s+ (car subtag) " (" (write-to-string (cdr subtag)) ")")))
                     (unless (= i 1)
                       (str ", "))))))))
      (unless base
        (htm
          (:div :class "category"
           (:h3 (:a :href (str (s+ base-url "/all")) "show all keywords"))))))))

(defun browse-all-inventory-tags (type &key base tags)
  (html
    (unless base
      (str (simple-inventory-entry-html type)))
    (let ((base-url (s+ "/" type "s")))
      (htm
        (:div :class "item"
        (:h2 "browse by keyword")
        (when base
          (htm
            (:p (:a :href (str base-url) (str (s+ "show all " type "s"))))
            (:p (:strong "keywords selected: ")) 
            (:ul :class "keywords"
              (dolist (tag base)
                (htm
                  (:li
                    (:a :href (format nil (s+ base-url "?kw=~{~a~^+~}") (remove tag base :test #'string=))
                        "[x]")
                    " "
                    (:a :href (format nil (s+ base-url "?kw=~a") tag) (str tag)) 
                    ))))))
        (dolist (tag tags)
          (htm
            (:div :class "category"
             (:h3 (:a :href (format nil (s+ base-url "?kw=~{~a+~}~a") base (first tag))
                      (str (s+ (first tag) " (" (write-to-string (second tag)) ")"))))
             (iter (for subtag in (third tag))
                   (for i downfrom (length (third tag)))
                   (if (string= (car subtag) "more")
                     (htm
                       (:a :href (format nil (s+ base-url "?kw=~{~a+~}~a") base (first tag)) (str (strcat "more (" (second tag) ")"))))
                     (htm
                     (:a :href (format nil (s+ base-url "?kw=~{~a+~}~a+~a") base (first tag) (first subtag))
                         (str (s+ (car subtag) " (" (write-to-string (cdr subtag)) ")")))
                     (unless (= i 1)
                       (str ", ")))))))))))))

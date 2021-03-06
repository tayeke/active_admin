module ActiveAdmin
  class ResourceController < ActiveAdminBaseController

    # This module overrides most of the data access methods in Inherited
    # Resources to provide Active Admin with it's data.
    #
    # The module also deals with authorization and resource callbacks.
    #
    module DataAccess

      def self.included(base)
        base.class_exec do
          include Callbacks
          include ScopeChain

          define_active_admin_callbacks :build, :create, :update, :save, :destroy
        end
      end

      protected

      # Retrieve, memoize and authorize the current collection from the db. This
      # method delegates the finding of the collection to #find_collection.
      #
      # Once #collection has been called, the collection is available using
      # either the @collection instance variable or an instance variable named
      # after the resource that the collection is for. eg: Post => @post.
      #
      # @returns [ActiveRecord::Relation] The collection for the index
      def collection
        get_collection_ivar || begin
          collection = find_collection
          authorize! Authorization::READ, active_admin_config.resource_class
          set_collection_ivar collection
        end
      end


      # Does the actual work of retrieving the current collection from the db.
      # This is a great method to override if you would like to perform
      # some additional db # work before your controller returns and
      # authorizes the collection.
      #
      # @returns [ActiveRecord::Relation] The collectin for the index
      def find_collection
        collection = scoped_collection

        collection = apply_authorization_scope(collection)
        collection = apply_sorting(collection)
        collection = apply_filtering(collection)
        collection = apply_scoping(collection)

        unless request.format == 'text/csv'
          collection = apply_pagination(collection)
        end

        collection = apply_collection_decorator(collection)

        collection
      end


      # Override this method in your controllers to modify the start point
      # of our searches and index.
      #
      # This method should return an ActiveRecord::Relation object so that
      # the searching and filtering can be applied on top
      #
      # Note, unless you are doing something special, you should use the
      # scope_to method from the Scoping module instead of overriding this
      # method.
      def scoped_collection
        end_of_association_chain
      end

      # Retrieve, memoize and authorize a resource based on params[:id]. The
      # actual work of finding the resource is done in #find_resource.
      #
      # This method is used on all the member actions:
      #
      #   * show
      #   * edit
      #   * update
      #   * destroy
      #
      # @returns [ActiveRecord::Base] An active record object
      def resource
        get_resource_ivar || begin
          resource = find_resource
          authorize_resource! resource

          resource = apply_decorator resource
          set_resource_ivar resource
        end
      end

      # Does the actual work of finding a resource in the database. This
      # method uses the finder method as defined in InheritedResources.
      #
      # Note that public_send can't be used here because Rails 3.2's
      # ActiveRecord::Associations::CollectionProxy (belongs_to associations)
      # mysteriously returns an Enumerator object.
      #
      # @returns [ActiveRecord::Base] An active record object.
      def find_resource
        scoped_collection.send method_for_find, params[:id]
      end


      # Builds, memoize and authorize a new instance of the resource. The
      # actual work of building the new instance is delegated to the
      # #build_new_resource method.
      #
      # This method is used to instantiate and authorize new resources in the
      # new and create controller actions.
      #
      # @returns [ActiveRecord::Base] An un-saved active record base object
      def build_resource
        get_resource_ivar || begin
          resource = build_new_resource
          run_build_callbacks resource
          authorize_resource! resource

          resource = apply_decorator resource
          set_resource_ivar resource
        end
      end

      # Builds a new resource. This method uses the method_for_build provided
      # by Inherited Resources.
      #
      # Note that public_send can't be used here w/ Rails 3.2 & a belongs_to
      # config, or you'll get undefined method `build' for []:Array.
      #
      # @returns [ActiveRecord::Base] An un-saved active record base object
      def build_new_resource
        scoped_collection.send method_for_build, *resource_params
      end

      # Calls all the appropriate callbacks and then creates the new resource.
      #
      # @param [ActiveRecord::Base] object The new resource to create
      #
      # @returns [void]
      def create_resource(object)
        run_create_callbacks object do
          save_resource(object)
        end
      end

      # Calls all the appropriate callbacks and then saves the new resource.
      #
      # @param [ActiveRecord::Base] object The new resource to save
      #
      # @returns [void]
      def save_resource(object)
        run_save_callbacks object do
          object.save
        end
      end

      # Update an object with the given attributes. Also calls the appropriate
      # callbacks for update action.
      #
      # @param [ActiveRecord::Base] object The instance to update
      #
      # @param [Array] attributes An array with the attributes in the first position
      #                           and the Active Record "role" in the second. The role
      #                           may be set to nil.
      #
      # @returns [void]
      def update_resource(object, attributes)
        if object.respond_to?(:assign_attributes)
          object.assign_attributes(*attributes)
        else
          object.attributes = attributes[0]
        end

        run_update_callbacks object do
          save_resource(object)
        end
      end

      # Destroys an object from the database and calls appropriate callbacks.
      #
      # @returns [void]
      def destroy_resource(object)
        run_destroy_callbacks object do
          object.destroy
        end
      end


      #
      # Collection Helper Methods
      #


      # Gives the authorization library a change to pre-scope the collection.
      #
      # In the case of the CanCan adapter, it calls `#accessible_by` on
      # the collection.
      #
      # @param [ActiveRecord::Relation] collection The collection to scope
      #
      # @retruns [ActiveRecord::Relation] a scoped collection of query
      def apply_authorization_scope(collection)
        action_name = action_to_permission(params[:action])
        active_admin_authorization.scope_collection(collection, action_name)
      end

      def apply_sorting(chain)
        params[:order] ||= active_admin_config.sort_order

        order_clause = OrderClause.new params[:order]

        if order_clause.valid?
          chain.reorder(order_clause.to_sql(active_admin_config))
        else
          chain # just return the chain
        end
      end

      # Applies any Ransack search methods to the currently scoped collection.
      # Both `search` and `ransack` are provided, but we use `ransack` to prevent conflicts.
      def apply_filtering(chain)
        @search = chain.ransack clean_search_params params[:q]
        @search.result
      end

      def clean_search_params(params)
        if params.is_a? Hash
          params.dup.delete_if{ |key, value| value.blank? }
        else
          {}
        end
      end

      def apply_scoping(chain)
        @collection_before_scope = chain

        if current_scope
          scope_chain(current_scope, chain)
        else
          chain
        end
      end

      def collection_before_scope
        @collection_before_scope
      end

      def current_scope
        @current_scope ||= if params[:scope]
          active_admin_config.get_scope_by_id(params[:scope])
        else
          active_admin_config.default_scope(self)
        end
      end

      def apply_pagination(chain)
        page_method_name = Kaminari.config.page_method_name
        page = params[Kaminari.config.param_name]

        chain.public_send(page_method_name, page).per(per_page)
      end

      def per_page
        if active_admin_config.paginate
          @per_page || active_admin_config.per_page
        else
          max_per_page
        end
      end

      def max_per_page
        10_000
      end

    end
  end
end

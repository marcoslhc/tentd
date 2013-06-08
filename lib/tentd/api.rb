require 'rack-putty'

module TentD
  class API

    POST_CONTENT_MIME = %(application/vnd.tent.post.v0+json).freeze
    MULTIPART_CONTENT_MIME = %(multipart/form-data).freeze

    POST_CONTENT_TYPE = %(#{POST_CONTENT_MIME}; type="%s").freeze
    ERROR_CONTENT_TYPE = %(application/vnd.tent.error.v0+json).freeze
    MULTIPART_CONTENT_TYPE = MULTIPART_CONTENT_MIME
    ATTACHMENT_DIGEST_HEADER = %(Attachment-Digest).freeze

    require 'tentd/api/serialize_response'
    require 'tentd/api/middleware'
    require 'tentd/api/user_lookup'
    require 'tentd/api/authentication'
    require 'tentd/api/authorization'
    require 'tentd/api/parse_input_data'
    require 'tentd/api/parse_content_type'
    require 'tentd/api/parse_link_header'
    require 'tentd/api/validate_input_data'
    require 'tentd/api/validate_post_content_type'
    require 'tentd/api/relationship_initialization'
    require 'tentd/api/oauth'

    include Rack::Putty::Router

    stack_base SerializeResponse

    middleware UserLookup
    middleware Authentication
    middleware Authorization
    middleware ParseInputData
    middleware ParseContentType
    middleware ParseLinkHeader
    middleware ValidateInputData

    class HelloWorld < Middleware
      def action(env)
        meta_post_url = TentD::Utils.expand_uri_template(
          env['current_user'].preferred_server['urls']['post'],
          :entity => env['current_user'].entity,
          :post => env['current_user'].meta_post.public_id
        )

        headers = {
          'Link' => %(<#{meta_post_url}>; rel="https://tent.io/rels/meta-post")
        }

        [201, headers, []]
      end
    end

    class GetPost < Middleware
      def action(env)
        params = env['params']
        env['response'] = Model::Post.first(:public_id => params[:post], :entity => params[:entity])
        env
      end
    end

    class AttachmentRedirect < Middleware
      def action(env)
        unless Model::Post === env['response']
          env.delete('response')
          return env
        end

        post = env.delete('response')
        params = env['params']

        if env['current_auth'] && (app_auth = env['current_auth.resource']) && TentType.new(app_auth.type).base == %(https://tent.io/types/app-auth)
          post_type = TentType.new(post.type)
          unless app_auth.content['post_types']['read'].any? { |uri|
            type = TentType.new(uri)
            uri == 'all' || (type.base == post_type.base && (type.has_fragment? ? type.fragment == post_type.fragment : true))
          }
            halt!(404, "Not Found")
          end
        else
          unless post.public
            halt!(404, "Not Found")
          end
        end

        accept = env['HTTP_ACCEPT'].to_s.split(';').first

        attachments = post.attachments.select { |a| a['name'] == params[:name] }

        unless accept == '*/*'
          attachments = attachments.select { |a| a['content_type'] == accept }
        end
        return env if attachments.empty?

        attachment = attachments.first

        attachment_url = Utils.expand_uri_template(env['current_user'].preferred_server['urls']['attachment'],
          :entity => post.entity,
          :digest => attachment['digest']
        )

        (env['response.headers'] ||= {})['Location'] = attachment_url
        env['response.status'] = 302

        env
      end
    end

    class GetAttachment < Middleware
      def action(env)
        params = env['params']

        attachment = Model::Attachment.where(:digest => params[:digest]).first
        halt!(404, "Not Found") unless attachment

        post_attachment = Model::PostsAttachment.where(:attachment_id => attachment.id).first
        halt!(404, "Not Found") unless post_attachment

        post = Model::Post.where(:id => post_attachment.post_id, :user_id => env['current_user'].id).first
        halt!(404, "Not Found") unless post

        if env['current_auth'] && (app_auth = env['current_auth.resource']) && TentType.new(app_auth.type).base == %(https://tent.io/types/app-auth)
          post_type = TentType.new(post.type)
          unless app_auth.content['post_types']['read'].any? { |uri|
            type = TentType.new(uri)
            uri == 'all' || (type.base == post_type.base && (type.has_fragment? ? type.fragment == post_type.fragment : true))
          }
            halt!(404, "Not Found")
          end
        else
          unless post.public
            halt!(404, "Not Found")
          end
        end

        env['response'] = attachment.data.lit
        (env['response.headers'] ||= {})['Content-Length'] = attachment.data.bytesize
        env['response.headers']['Content-Type'] = post_attachment.content_type
        env
      end
    end

    class CreatePost < Middleware
      def action(env)
        if env['request.notification']
          case env['request.type'].base
          when "https://tent.io/types/relationship"
            RelationshipInitialization.call(env)
          end
        else
          post = Model::Post.create_from_env(env)
          env['response'] = post.latest_version

          if %w( https://tent.io/types/app https://tent.io/types/app-auth ).include?(TentType.new(post.type).base) && !env['request.import']
            if TentType.new(post.type).base == "https://tent.io/types/app"
              # app
              credentials_post = Model::Post.first(:id => Model::App.first(:user_id => env['current_user'].id, :post_id => post.id).credentials_post_id)
            else
              # app-auth
              credentials_post = Model::Post.qualify.join(:mentions, :posts__id => :mentions__post_id).where(
                :mentions__post => post.public_id,
                :posts__type_id => Model::Type.find_or_create_full('https://tent.io/types/credentials/v0#').id
              ).first
            end

            current_user = env['current_user']
            (env['response.links'] ||= []) << {
              :url => TentD::Utils.sign_url(
                current_user.server_credentials,
                TentD::Utils.expand_uri_template(
                  current_user.preferred_server['urls']['post'],
                  :entity => current_user.entity,
                  :post => credentials_post.public_id
                )
              ),
              :rel => "https://tent.io/rels/credentials"
            }
          end
        end
        env
      end
    end

    class CreatePostVersion < Middleware
      def action(env)
        unless env['current_auth'] && (app_auth = env['current_auth.resource']) && TentType.new(app_auth.type).base == %(https://tent.io/types/app-auth) && (post_type = TentType.new(env['data']['type'])) && app_auth.content['post_types']['write'].any? { |uri|
          type = TentType.new(uri)
          uri == 'all' || (type.has_fragment? ? type == post_type : type.base == post_type.base)
        }
          if env['current_auth']
            halt!(403, "Unauthorized")
          else
            halt!(401, "Unauthorized")
          end
        end

        env['response'] = Model::Post.create_version_from_env(env)
        env
      end
    end

    class PostsFeed < Middleware
      def action(env)
        env['response'] = Feed.new(env)
        env
      end
    end

    head '/' do |b|
      b.use HelloWorld
    end

    post '/posts' do |b|
      b.use ValidatePostContentType
      b.use CreatePost
    end

    get '/posts/:entity/:post' do |b|
      b.use GetPost
    end

    put '/posts/:entity/:post' do |b|
      b.use CreatePostVersion
    end

    get '/posts/:entity/:post/attachments/:name' do |b|
      b.use GetPost
      b.use AttachmentRedirect
    end

    get '/attachments/:entity/:digest' do |b|
      b.use GetAttachment
    end

    get '/posts' do |b|
      b.use PostsFeed
    end

    get '/oauth/authorize' do |b|
      b.use OAuth::Authorize
    end

    post '/oauth/token' do |b|
      b.use OAuth::Token
    end

  end
end

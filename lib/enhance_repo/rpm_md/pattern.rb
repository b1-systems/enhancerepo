#--
# 
# enhancerepo is a rpm-md repository metadata tool.
# Copyright (C) 2008, 2009 Novell Inc.
#
# Author: Michael Calmer <mc@suse.de>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA  02110-1301, USA.  A copy of the GNU General Public License is
# also available at http://www.gnu.org/copyleft/gpl.html.
#
#++
#

require 'rubygems'
require 'nokogiri'
require 'rexml/document'
require 'yaml'
require 'prettyprint'
require 'fileutils'
require 'zlib'
require 'stringio'
require 'enhance_repo/rpm_md/update'

module EnhanceRepo
  module RpmMd

    # helper to write out a pattern in
    # rpmmd format
    module PatternWriter

      def to_xml
        buffer = StringIO.new
        write_xml(buffer)
        buffer.string
      end
        
      def write_xml(io = STDOUT)
        pattern = self
        builder = Nokogiri::XML::Builder.new(:encoding => 'UTF-8') do |xml|
          xml.pattern('xmlns' => "http://novell.com/package/metadata/suse/pattern",
                      'xmlns:rpm' => "http://linux.duke.edu/metadata/rpm") {
            xml.name pattern.name
            xml.version 'epoch' => '0', 'ver' => pattern.version, 'rel' => pattern.release
            xml.arch pattern.architecture
            xml.icon pattern.icon if pattern.icon
            xml.order pattern.order
            pattern.summary.each do |lang, text|
              if lang.empty?
                xml.summary text
              else
                xml.summary text, 'lang' => "#{lang}"
              end
            end
            pattern.description.each do |lang, text|
              if lang.empty?
                xml.description text
              else
                xml.description text, 'lang' => "#{lang}"
              end
            end
            xml.uservisible if pattern.visible
            pattern.category.each do |lang, text|
              if lang.empty?
                xml.category text
              else
                xml.category text, 'lang' => "#{lang}"
              end
            end
            if ! pattern.conflicts.empty?
              xml['rpm'].conflicts {
                pattern.conflicts.each do |pkg, kind|
                  if kind == "package"
                    xml['rpm'].entry( 'name' => pkg )
                  else
                    xml['rpm'].entry( 'name' => "#{kind}:#{pkg}" )
                  end
                end
              }
            end
            if ! pattern.supplements.empty?
              xml['rpm'].supplements {
                pattern.supplements.each do |pkg, kind|
                  if kind == "package"
                    xml['rpm'].entry( 'name' => pkg )
                  else
                    xml['rpm'].entry( 'name' => "#{kind}:#{pkg}" )
                  end
                end
              }
            end
            if ! pattern.provides.empty?
              xml['rpm'].provides {
                pattern.provides.each do |pkg, kind|
                  if kind == "package"
                    xml['rpm'].entry( 'name' => pkg )
                  else
                    xml['rpm'].entry( 'name' => "#{kind}:#{pkg}" )
                  end
                end
              }
            end
            if ! pattern.requires.empty?
              xml['rpm'].requires {
                pattern.requires.each do |pkg, kind|
                  if kind == "package"
                    xml['rpm'].entry( 'name' => pkg )
                  else
                    xml['rpm'].entry( 'name' => "#{kind}:#{pkg}" )
                  end
                end
              }
            end
            if ! pattern.recommends.empty?
              xml['rpm'].recommends {
                pattern.recommends.each do |pkg, kind|
                  if kind == "package"
                    xml['rpm'].entry( 'name' => pkg )
                  else
                    xml['rpm'].entry( 'name' => "#{kind}:#{pkg}" )
                  end
                end
              }
            end
            if ! pattern.suggests.empty?
              xml['rpm'].suggests {
                pattern.suggests.each do |pkg, kind|
                  if kind == "package"
                    xml['rpm'].entry( 'name' => pkg )
                  else
                    xml['rpm'].entry( 'name' => "#{kind}:#{pkg}" )
                  end
                end
              }
            end
            if ! pattern.extends.empty?
              xml.extends {
                pattern.extends.each do |pkg, kind|
                  xml.item( 'pattern' => pkg ) if kind == "pattern"
                end
              }
            end
            if ! pattern.includes.empty?
              xml.includes {
                pattern.includes.each do |pkg, kind|
                   xml.item( 'pattern' => pkg ) if kind == "pattern"
                end
              }
            end
          }
        end
        io << builder.to_xml
      end
    end
    
    class Patterns < Data
      
      class PatternData

        include PatternWriter
        
        attr_accessor :name
        attr_accessor :version
        attr_accessor :release
        attr_accessor :architecture
        attr_accessor :summary
        attr_accessor :description
        attr_accessor :icon
        attr_accessor :order
        attr_accessor :visible
        attr_accessor :category
        attr_accessor :supplements
        attr_accessor :conflicts
        attr_accessor :provides
        attr_accessor :requires
        attr_accessor :recommends
        attr_accessor :suggests
        attr_accessor :extends
        attr_accessor :includes
        
        
        def initialize
          @name        = ""
          @version     = ""
          @release     = ""
          @architecture = "noarch"
          @summary     = Hash.new
          @description = Hash.new
          @icon        = nil
          @order       = 0
          @visible     = true
          @category    = Hash.new
          @supplements = Hash.new
          @conflicts   = Hash.new
          @provides    = Hash.new
          @requires    = Hash.new
          @recommends  = Hash.new
          @suggests    = Hash.new
          @extends     = Hash.new
          @includes    = Hash.new
        end
          
      end
      
      def initialize(config)
        @dir = config.dir
        @basedir = config.updatesbasedir

        # update files
        @patterns = Set.new
      end

      def empty?
        @patterns.empty?
      end

      def size
        @patterns.size
      end

      # add all patterns in a repoparts directory
      # by default look in repoparts/
      # otherwise pass the :repoparts_path option
      def read_repoparts(opts={})
        repoparts_path = opts[:repoparts_path] || File.join(@dir, 'repoparts')
        log.info "Reading patterns parts from #{repoparts_path}"
        Dir[File.join(repoparts_path, 'pattern-*.xml')].each do |patternfile|
          log.info("`-> adding pattern #{patternfile}")
          @patterns << patternfile
        end
        # end of directory iteration
      end

      # generates a patterns.xml from a list of package names
      # it compares the last version of those package names
      # with their previous ones
      #
      # outputdir is the directory where to save the patch to.      
      def generate_patterns(files, outputdir)
        pats = []
        pattern = nil
        files.each do |file|
          raise "#{file} does not exist" if not File.exist?(file)

          in_des = false
          in_req = false
          in_rec = false
          in_sug = false
          in_sup = false
          in_con = false
          in_prv = false
          in_ext = false
          in_inc = false
          kind = "package"
          cur_lang = ""
          description = ""
          requires = Array.new
          recommends = Array.new
          suggests = Array.new
          Zlib::GzipReader.open(file) do |gz|
            gz.each_line do |line|
              if line.start_with?("=Pat:")
                # save the previous one
                pats << pattern if not pattern.nil?
                # a new patern starts here
                pattern = PatternData.new
                v = line.split(/:\s*/, 2)
                a = v[1].chomp.split(/\s/, 4)
                pattern.name = a[0] if a.length >= 1
                pattern.version = a[1] if a.length >= 2
                pattern.release = a[2] if a.length >= 3
                pattern.architecture = a[3] if a.length >= 4
              elsif line.start_with?("=Cat")
                v = line.match(/=Cat\.?(\w*):\s*(.*)$/)
                pattern.category["#{v[1]}"] = v[2].chomp
              elsif line.start_with?("=Sum")
                v = line.match(/=Sum\.?(\w*):\s*(.*)$/)
                pattern.summary["#{v[1]}"] = v[2].chomp
              elsif line.start_with?("=Ico:")
                v = line.split(/:\s*/, 2)
                pattern.icon = v[1].chomp
              elsif line.start_with?("=Ord:")
                v = line.split(/:\s*/, 2)
                pattern.order = v[1].chomp.to_i
              elsif line.start_with?("=Vis:")
                if line.include?("true")
                  pattern.visible = true
                else
                  pattern.visible = false
                end
              elsif line.start_with?("+Des")
                in_des = true
                cur_lang = line.match(/\+Des\.?(\w*):/)[1]
              elsif line.start_with?("-Des")
                in_des = false
                pattern.description[cur_lang] = description
                cur_lang = ""
                description = ""
              elsif line.start_with?("+Req:")
                in_req = true
                kind = "pattern"
              elsif line.start_with?("-Req:")
                in_req = false
                kind = "package"
              elsif line.start_with?("+Sup:")
                in_sup = true
                kind = "pattern"
              elsif line.start_with?("-Sup:")
                in_sup = false
                kind = "package"
              elsif line.start_with?("+Con:")
                in_con = true
                kind = "pattern"
              elsif line.start_with?("-Con:")
                in_con = false
                kind = "package"
              elsif line.start_with?("+Prv:")
                in_prv = true
                kind = "pattern"
              elsif line.start_with?("-Prv:")
                in_prv = false
                kind = "package"
              elsif line.start_with?("+Prc:")
                in_rec = true
                kind = "package"
              elsif line.start_with?("-Prc:")
                in_rec = false
              elsif line.start_with?("+Prq:")
                in_req = true
                kind = "package"
              elsif line.start_with?("-Prq:")
                in_req = false
              elsif line.start_with?("+Psg:")
                in_sug = true
                kind = "package"
              elsif line.start_with?("-Psg:")
                in_sug = false
              elsif line.start_with?("+Ext:")
                in_ext = true
                kind = "pattern"
              elsif line.start_with?("-Ext:")
                in_ext = false
                kind = "package"
              elsif line.start_with?("+Inc:")
                in_req = true
                kind = "pattern"
              elsif line.start_with?("-Inc:")
                in_inc = false
                kind = "package"
              elsif in_des
                description << line
              elsif in_con
                pattern.conflicts[line.chomp] = kind
              elsif in_sup
                pattern.supplements[line.chomp] = kind
              elsif in_prv
                pattern.provides[line.chomp] = kind
              elsif in_req
                pattern.requires[line.chomp] = kind
              elsif in_rec
                pattern.recommends[line.chomp] = kind
              elsif in_sug
                pattern.suggests[line.chomp] = kind
              elsif in_ext
                pattern.extends[line.chomp] = kind
              elsif in_inc
                pattern.includes[line.chomp] = kind
              end
            end
          end
        end
        pats << pattern if not pattern.nil?
        
        FileUtils.mkdir_p(outputdir)
        pats.each do |pat|
          pattern_filename = File.join(outputdir, "pattern-#{pat.name}_0.xml")
          File.open(pattern_filename, 'w') do |f|
            log.info "write pattern #{pattern_filename}"
            pat.write_xml(f)
           end
        end
      end

      # splits the patterns.xml file into serveral pattern files
      # it writes those files into outputdir
      # output filenames will be pattern-name_<num>.xml
      # where name is the name of the pattern
      #
      # outputdir is the directory where to save the pattern to.
      def split_patterns(outputdir)
        FileUtils.mkdir_p outputdir
        patternsfile = File.join(@dir, metadata_filename)

        # we can't split without an patterns file
        raise "#{patternsfile} does not exist" if not File.exist?(patternsfile)
        Zlib::GzipReader.open(patternsfile) do |gz|
          document = REXML::Document.new(gz)
          root = document.root
          root.each_element("pattern") do |patternElement|
            name = nil
            patternElement.each_element("name") do |elementName|
              name = elementName.text
            end
            if name == nil
              log.warning 'No name found. Setting name to NON_NAME_FOUND'
              name = 'NON_NAME_FOUND'
            end
            version = 0
            updatefilename = ""
            while ( File.exists?(patternfilename = File.join(outputdir, "pattern-#{name}_#{version.to_s}.xml") ) )
              version += 1
            end
            log.info "Saving pattern part to '#{patternfilename}'."
            File.open(patternfilename, 'w') do |patternfile|
              patternfile << patternElement
              patternfile << "\n"
            end
          end
        end
      end

      # write a update out
      def write(file)
        builder = Builder::XmlMarkup.new(:target=>file, :indent=>2)
        builder.instruct!
        xml = builder.patterns('xmlns' => "http://novell.com/package/metadata/suse/pattern",
                               'xmlns:rpm' => "http://linux.duke.edu/metadata/rpm") do |b|
          pattern_regex = Regexp.new('<pattern\s+xmlns.+>\s*$');
          @patterns.each do |pattern|
            File.open(pattern).each_line do |line|
              if ! line.start_with?("<?xml")
                if line.match(pattern_regex)
                  # all single pattern have the namespace attributes
                  # we can remove them in the combined file
                  file << "<pattern>\n"
                else
                  file << line
                end
              end
            end
          end
        end #done builder
      end
    end
  end
end

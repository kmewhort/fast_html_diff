# FastHtmlDiff

This gem performs a diff on two input HTML files (outputting the result in HTML as well).  It's built for speed, using
tried-and-true UNIX diff as the LCS algorithm. The implementation works directly on the DOM to ensure the output
always remains valid.

## Installation

Add this line to your application's Gemfile:

    gem 'fast_html_diff'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install fast_html_diff

## Usage

Basic usage:

    result_html_str = FastHtmlDiff::DiffBuilder.new(string_a,string_b).build

With options (see below for details):

    result_html_str = FastHtmlDiff::DiffBuilder.new(string_a,string_b, simplify_html: true, try_hard: true).build

## Options

* ignore_punctuation: boolean [default: true]
* case_insensitive: boolean [default: true]
* tokenizer_regexp: regexp [default: %r{([^A-Za-z0-9]+)};] Make sure to include the outer parentheses. This option overrides any "ignore_punctuation" setting.
* diff_cmd: str [default: 'diff']. May be useful if you only have diff available through cygwin or a WWindows port.
* try_hard: boolean [default: false]. Try hard to find smaller-length matches (at a bit of a performance cost).
* simplify_html: boolean [default: false]. Strips HTML to only the permitted tags, giving better output format where the structure of the two inputs differ greatly.
* simplified_html_tags: array of strings [default %w(html body p strong em ul ol li)]

## Styling

Insertions are wrapped in "<ins>"; Deletions are wrapped "<del>".  Add the following CSS for much nicer looking output:

    ins {
        text-decoration: none;
        background-color: #a3ffad;
    }
    del {
        color: #ff5d5a;
        background-color: #b4ecff;
    }

## License

(c) 2013, Kent Mewhort, licensed under BSD. See LICENSE.txt for details.


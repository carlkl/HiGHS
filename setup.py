
import sys
import pathlib
from datetime import datetime

#from setuptools.command.build_clib import build_clib as _build_clib

#class build_clib(_build_clib):
#    def build_libraries(self, libraries):
#        #from scipy._build_utils.compiler_helper import get_cxx_std_flag
#        #std_flag = get_cxx_std_flag(build_ext._cxx_compiler)
#        #if std_flag is not None:
#        #    ext.extra_compile_args.append(std_flag)
#        print(libraries)
#
#        _build_clib.build_libraries(libraries)

def pre_build_hook(build_ext, ext):
    from scipy._build_utils.compiler_helper import get_cxx_std_flag
    std_flag = get_cxx_std_flag(build_ext._cxx_compiler)
    if std_flag is not None:
        ext.extra_compile_args.append(std_flag)

def _get_sources(CMakeLists, start_token, end_token):
    # Read in sources from CMakeLists.txt
    CMakeLists = pathlib.Path(__file__).parent / CMakeLists
    with open(CMakeLists, 'r') as f:
        s = f.read()

        # Find block where sources are listed
        start_idx = s.find(start_token) + len(start_token)
        end_idx = s[start_idx:].find(end_token) + len(s[:start_idx])
        sources = s[start_idx:end_idx].split('\n')
        sources = [s.strip() for s in sources if s[0] != '#']

    # Make relative to setup.py
    sources = [str(pathlib.Path('src/' + s)) for s in sources]
    return sources

# Grab some more info about HiGHS from root CMakeLists
def _get_version(CMakeLists, start_token, end_token=')'):
    CMakeLists = pathlib.Path(__file__).parent / CMakeLists
    with open(CMakeLists, 'r') as f:
        s = f.read()
        start_idx = s.find(start_token) + len(start_token) + 1
        end_idx = s[start_idx:].find(end_token) + len(s[:start_idx])
    return s[start_idx:end_idx].strip()


def configuration(parent_package='', top_path=None):

    from numpy.distutils.misc_util import Configuration
    config = Configuration('_highs', parent_package, top_path)

    # HiGHS info
    HIGHS_VERSION_MAJOR = _get_version('CMakeLists.txt', 'HIGHS_VERSION_MAJOR')
    HIGHS_VERSION_MINOR = _get_version('CMakeLists.txt', 'HIGHS_VERSION_MINOR')
    HIGHS_VERSION_PATCH = _get_version('CMakeLists.txt', 'HIGHS_VERSION_PATCH')
    GITHASH = 'n/a'
    HIGHS_DIR = str(pathlib.Path(__file__).parent.resolve())

    # Here are the pound defines that HConfig.h would usually provide;
    # We provide an empty HConfig.h file and do the defs and undefs
    # here:
    TODAY_DATE = datetime.today().strftime('%Y-%m-%d')
    # ('OPENMP', None), ?
    DEFINE_MACROS = [
        ('CMAKE_BUILD_TYPE', '"Release"'),
        ('HiGHSRELEASE', None),
        ('IPX_ON', 'ON'),
        ('HIGHS_GITHASH', '"%s"' % GITHASH),
        ('HIGHS_COMPILATION_DATE', '"' + TODAY_DATE + '"'),
        ('HIGHS_VERSION_MAJOR', HIGHS_VERSION_MAJOR),
        ('HIGHS_VERSION_MINOR', HIGHS_VERSION_MINOR),
        ('HIGHS_VERSION_PATCH', HIGHS_VERSION_PATCH),
        ('HIGHS_DIR', '"' + HIGHS_DIR + '"'),
    ]
    UNDEF_MACROS = [
        'OPENMP',  # unconditionally disable openmp
        'EXT_PRESOLVE',
        'SCIP_DEV',
        'HiGHSDEV',
        'OSI_FOUND',
    ]

    # Compile BASICLU as a static library to appease clang:
    # (won't allow -std=c++11/14 option for C sources)
    basiclu_sources = _get_sources('src/CMakeLists.txt',
                                   'set(basiclu_sources\n', ')')
    config.add_library(
        'basiclu',
        sources=basiclu_sources,
        include_dirs=[
            'src/',
            'src/ipm/basiclu/include/',
        ],
        language='c',
        macros=DEFINE_MACROS,
    )

    # Compile ipx and highs as static libraries;
    # must pass _pre_build_hook as build_info member:
    # see https://github.com/scipy/scipy/blob/2190a7427a8d10a3a506294e87ff1330c426cb63/setup.py#L299
    ipx_sources = _get_sources('src/CMakeLists.txt', 'set(ipx_sources\n', ')')
    config.add_library(
        'ipx',
        sources=ipx_sources,
        include_dirs=[
            'src/ipm/ipx/include/',
            'src/ipm/basiclu/include/',
        ],
        libraries=['basiclu'],
        language='c++',
        macros=DEFINE_MACROS,
        _pre_build_hook=pre_build_hook,
    )
    highs_sources = _get_sources('src/CMakeLists.txt', 'set(sources\n', ')')
    config.add_library(
        'highs',
        sources=highs_sources,
        include_dirs=[
            'src/',
            'src/io/',
            'src/ipm/ipx/include/',
        ],
        libraries=['ipx'],
        language='c++',
        macros=DEFINE_MACROS,
        _pre_build_hook=pre_build_hook,
    )

    # highs_wrapper:
    ext = config.add_extension(
        'highs_wrapper',
        sources=['pyHiGHS/src/highs_wrapper.cxx'],
        include_dirs=[
            'pyHiGHS/src/',
            'src/',
            'src/lp_data/',
        ],
        language='c++',
        libraries=['highs'],
        define_macros=DEFINE_MACROS,
        undef_macros=UNDEF_MACROS,
    )
    # Add c++11/14 support:
    ext._pre_build_hook = pre_build_hook

    # wrapper around HiGHS writeMPS:
    ext = config.add_extension(
        'mpswriter',
        sources=['pyHiGHS/src/mpswriter.cxx'],
        include_dirs=[
            'pyHiGHS/src/',
            'src/',
            'src/io/',
            'src/lp_data/',
        ],
        language='c++',
        libraries=['highs'],
        define_macros=DEFINE_MACROS,
        undef_macros=UNDEF_MACROS,
    )
    ext._pre_build_hook = pre_build_hook

    return config


if __name__ == '__main__':
    from numpy.distutils.core import setup
    setup(**configuration(top_path='').todict())

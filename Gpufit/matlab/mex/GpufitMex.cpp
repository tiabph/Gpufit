#include "Gpufit/gpufit.h"

#include <mex.h>

#include <cstring>
#include <string>

/*
	Get a arbitrary scalar (non complex) and check for class id.
	https://www.mathworks.com/help/matlab/apiref/mxclassid.html
*/
template<class T> inline bool get_scalar(const mxArray *p, T &v, const mxClassID id)
{
	if (mxIsNumeric(p) && !mxIsComplex(p) && mxGetNumberOfElements(p) == 1 && mxGetClassID(p) == id)
	{
		v = *static_cast<T *>(mxGetData(p));
		return true;
	}
	else {
		return false;
	}
}

void mexFunction(
    int          nlhs,
    mxArray      *plhs[],
    int          nrhs,
    mxArray const *prhs[])
{
    int expected_nrhs = 0;
    int expected_nlhs = 0;
    bool wrong_nrhs = false;
    bool wrong_nlhs = false;

    // expects a certain number of input (nrhs) and output (nlhs) arguments
    expected_nrhs = 13;
    expected_nlhs = 4;
    if (nrhs != expected_nrhs)
    {
        wrong_nrhs = true;
    }
    else if (nlhs != expected_nlhs)
    {
        wrong_nlhs = true;
    }

    if (wrong_nrhs || wrong_nlhs)
    {
        if (nrhs != expected_nrhs)
        {
            char s1[50];
            _itoa_s(expected_nrhs, s1, 10);
            char const s2[] = " input arguments required.";
            size_t const string_length = strlen(s1) + 1 + strlen(s2);
            strcat_s(s1, string_length, s2);
            mexErrMsgIdAndTxt("Gpufit:Mex", s1);
        }
        else if (nlhs != expected_nlhs)
        {
            char s1[50];
            _itoa_s(expected_nlhs, s1, 10);
            char const s2[] = " output arguments required.";
            size_t const string_length = strlen(s1) + 1 + strlen(s2);
            strcat_s(s1, string_length, s2);
            mexErrMsgIdAndTxt("Gpufit:Mex", s1);
        }
    }

	// input parameters
	float * data = (float*)mxGetPr(prhs[0]);
	float * weights = (float*)mxGetPr(prhs[1]);
    std::size_t n_fits = (std::size_t)*mxGetPr(prhs[2]);
    std::size_t n_points = (std::size_t)*mxGetPr(prhs[3]);

	// tolerance
	float tolerance = 0;
	if (!get_scalar(prhs[4], tolerance, mxSINGLE_CLASS))
	{
		mexErrMsgIdAndTxt("Gpufit:Mex", "tolerance is not a single");
	}

	// max_n_iterations
	int max_n_iterations = 0;
	if (!get_scalar(prhs[5], max_n_iterations, mxINT32_CLASS))
	{
		mexErrMsgIdAndTxt("Gpufit:Mex", "max_n_iteration is not int32");
	}

    int estimator_id = (int)*mxGetPr(prhs[6]);
	float * initial_parameters = (float*)mxGetPr(prhs[7]);
	int * parameters_to_fit = (int*)mxGetPr(prhs[8]);
    int model_id = (int)*mxGetPr(prhs[9]);
    int n_parameters = (int)*mxGetPr(prhs[10]);
	int * user_info = (int*)mxGetPr(prhs[11]);
    std::size_t user_info_size = (std::size_t)*mxGetPr(prhs[12]);

	// output parameters
    float * output_parameters;
	mxArray * mx_parameters;
	mx_parameters = mxCreateNumericMatrix(1, n_fits*n_parameters, mxSINGLE_CLASS, mxREAL);
	output_parameters = (float*)mxGetData(mx_parameters);
	plhs[0] = mx_parameters;

    int * output_states;
	mxArray * mx_states;
	mx_states = mxCreateNumericMatrix(1, n_fits, mxINT32_CLASS, mxREAL);
	output_states = (int*)mxGetData(mx_states);
	plhs[1] = mx_states;

    float * output_chi_squares;
	mxArray * mx_chi_squares;
	mx_chi_squares = mxCreateNumericMatrix(1, n_fits, mxSINGLE_CLASS, mxREAL);
	output_chi_squares = (float*)mxGetData(mx_chi_squares);
	plhs[2] = mx_chi_squares;

    int * output_n_iterations;
    mxArray * mx_n_iterations;
    mx_n_iterations = mxCreateNumericMatrix(1, n_fits, mxINT32_CLASS, mxREAL);
    output_n_iterations = (int*)mxGetData(mx_n_iterations);
    plhs[3] = mx_n_iterations;

	// call to gpufit
    int const status
            = gpufit
            (
                n_fits,
                n_points,
                data,
                weights,
                model_id,
                initial_parameters,
                tolerance,
                max_n_iterations,
                parameters_to_fit,
                estimator_id,
                user_info_size,
                reinterpret_cast< char * >( user_info ),
                output_parameters,
                output_states,
                output_chi_squares,
                output_n_iterations
            ) ;

	// check status
    if (status != STATUS_OK)
    {
        std::string const error = gpufit_get_last_error() ;
        mexErrMsgIdAndTxt( "Gpufit:Mex", error.c_str() ) ;
    }
}
